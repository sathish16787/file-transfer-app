#!/usr/bin/env bash
# =============================================================================
# leidos-cert-change.sh - Replace the DataOS dev public TLS certificate (Leidos)
#
# Run ONE stage at a time, in order, and check the output before the next:
#   ./leidos-cert-change.sh preflight   # read-only: tools, context, files
#   ./leidos-cert-change.sh build       # local only: full chain, JKS, secret files
#   ./leidos-cert-change.sh backup      # read-only: backup all 15 copies
#   ./leidos-cert-change.sh freeze      # scale caretaker sync to 0
#   ./leidos-cert-change.sh master      # replace dataos-system master, verify
#   ./leidos-cert-change.sh copies      # replace the 14 copies, verify all
#   ./leidos-cert-change.sh unfreeze    # restore caretaker, verify nothing reverts
#   ./leidos-cert-change.sh restart     # restart consumers + heimdall-api
#   ./leidos-cert-change.sh verify      # check every namespace + live endpoint
#   ./leidos-cert-change.sh rollback    # restore the backups (only if needed)
#
# Put these 4 files from IdenTrust next to this script before starting:
#   dataos-dev.crt  dataos-dev.key  SubCA1.txt  Root.txt
# Works with macOS bash 3.2 and LibreSSL. Needs: kubectl, jq, openssl, keytool.
# =============================================================================
set -uo pipefail

SECRET="dataos-dev-leidos-com"
MASTER_NS="dataos-system"
EXPECTED_CONTEXT="dataos-ck-eks-poc-us-gov"
HOST="dataos-dev.leidos.com"
NEW_SERIAL="4001A1EF8B35C63A6B5C45A9F6B52EC0"
CARETAKER_NS="caretaker"
CARETAKER_DEPLOYS="${CARETAKER_DEPLOYS:-caretaker-api}"   # confirm from discovery-2
JKS_PW_SECRET="jks-password-secret"
JKS_PW_KEY="password-key"

CRT="dataos-dev.crt"; KEY="dataos-dev.key"; SUB="SubCA1.txt"; ROOT="Root.txt"
WORK="./work"; BACKUP="$WORK/backup"
mkdir -p "$WORK" "$BACKUP"; chmod 700 "$WORK" "$BACKUP"
umask 077

RESTART_LIST="
deploy caretaker/gateway-audit-receiver
deploy caretaker/lens2-audit-receiver
deploy caretaker/page-event-receiver
deploy caretaker/query-audit-receiver
deploy core-apps/bifrost-app
deploy core-apps/dph-discover
deploy core-apps/dph-explore
deploy core-apps/home-app
deploy core-apps/operations-app
deploy core-apps/sql-workbench
deploy core-apps/vision-service
deploy depot/asset-metastore-service
deploy depot/depotservice-api
deploy depot/dialect-translator
deploy metis/metis
deploy network-gateway/gateway
deploy network-gateway/postern
deploy poros/stack-exec-context-sink
statefulset network-gateway/network-gateway-peer-server
statefulset sentinel/prometheus-prometheus-prometheus
deploy heimdall/heimdall-api
"

LOG="$WORK/change-$(date +%F).log"
say()  { echo "$*" | tee -a "$LOG"; }
ok()   { say "  [OK]   $*"; }
fail() { say "  [FAIL] $*"; exit 1; }
warn() { say "  [WARN] $*"; }
b64()  { base64 < "$1" | tr -d '\n'; }
confirm() { printf "%s Type YES to continue: " "$1"; read -r a; [ "$a" = "YES" ] || { say "Stopped by user."; exit 1; }; }

check_context() {
  ctx=$(kubectl config current-context 2>/dev/null)
  case "$ctx" in *"$EXPECTED_CONTEXT"*) ok "context: $ctx" ;; *) fail "wrong context: '$ctx' (expected *$EXPECTED_CONTEXT*)";; esac
}
namespaces() { kubectl get secret -A --field-selector metadata.name="$SECRET" -o jsonpath='{.items[*].metadata.namespace}'; }
serial_in() { kubectl get secret "$SECRET" -n "$1" -o jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; }
show_all() {
  allnew=0
  for ns in $(namespaces); do
    s=$(serial_in "$ns"); sync=$(kubectl get secret "$SECRET" -n "$ns" -o json | jq -r '.metadata.annotations["caretaker.dataos.io/sync"] // "-"')
    if [ "$s" = "$NEW_SERIAL" ]; then mark="NEW"; else mark="OLD"; allnew=1; fi
    say "$(printf '  %-18s %-4s serial=%s sync=%s' "$ns" "$mark" "$s" "$sync")"
  done
  return $allnew
}

stage_preflight() {
  say "== PREFLIGHT (read-only)"
  for t in kubectl jq openssl keytool base64; do command -v $t >/dev/null && ok "$t found" || fail "$t not installed"; done
  check_context
  for f in "$CRT" "$KEY" "$SUB" "$ROOT"; do [ -s "$f" ] && ok "file $f" || fail "missing $f"; done
  m1=$(openssl x509 -noout -modulus -in "$CRT" | openssl md5); m2=$(openssl rsa -noout -modulus -in "$KEY" 2>/dev/null | openssl md5)
  [ "$m1" = "$m2" ] && ok "key matches certificate" || fail "key does NOT match certificate"
  s=$(openssl x509 -in "$CRT" -noout -serial | cut -d= -f2)
  [ "$s" = "$NEW_SERIAL" ] && ok "new cert serial $s" || fail "unexpected serial $s"
  openssl x509 -in "$CRT" -noout -subject -dates | sed 's/^/  /' | tee -a "$LOG"
  kubectl get secret "$SECRET" -n "$MASTER_NS" >/dev/null 2>&1 && ok "secret $SECRET exists in $MASTER_NS" || fail "secret not found"
  say "  Copies in: $(namespaces)"
  say "  Caretaker deployments to freeze: $CARETAKER_DEPLOYS"
  kubectl get deploy,hpa -n "$CARETAKER_NS" 2>&1 | sed 's/^/  /' | tee -a "$LOG"
  say "== PREFLIGHT done. Next: build"
}

stage_build() {
  say "== BUILD (local files only, nothing applied)"
  check_context
  # 1. clean full chain (strips CRLF, fixes missing trailing newline)
  for f in "$CRT" "$SUB" "$ROOT"; do openssl x509 -in "$f"; done > "$WORK/fullchain.pem"
  n=$(grep -c 'BEGIN CERTIFICATE' "$WORK/fullchain.pem"); [ "$n" = "3" ] && ok "fullchain has 3 certs" || fail "fullchain has $n certs"
  grep -q $'\r' "$WORK/fullchain.pem" && fail "CRLF still present" || ok "no CRLF"
  openssl verify -CAfile "$ROOT" -untrusted "$SUB" "$CRT" >/dev/null 2>&1 && ok "chain verifies" || fail "chain does not verify"

  # 2. JKS with the cluster's existing password and alias
  JKS_PW=$(kubectl get secret "$JKS_PW_SECRET" -n "$MASTER_NS" -o jsonpath="{.data.$JKS_PW_KEY}" | base64 --decode)
  [ -n "$JKS_PW" ] || fail "could not read JKS password"
  kubectl get secret "$SECRET" -n "$MASTER_NS" -o jsonpath='{.data.keystore\.jks}' | base64 --decode > "$WORK/old.jks"
  ALIAS=$(keytool -list -v -keystore "$WORK/old.jks" -storepass "$JKS_PW" 2>/dev/null | awk -F': ' '/^Alias name/{print $2; exit}')
  if [ -z "$ALIAS" ]; then warn "could not read old alias, using 'certificate'"; ALIAS="certificate"; else ok "existing JKS alias: $ALIAS"; fi
  rm -f "$WORK/new.p12" "$WORK/keystore.jks"
  openssl pkcs12 -export -in "$WORK/fullchain.pem" -inkey "$KEY" -name "$ALIAS" -out "$WORK/new.p12" -passout pass:"$JKS_PW" || fail "pkcs12 export failed"
  keytool -importkeystore -srckeystore "$WORK/new.p12" -srcstoretype PKCS12 -srcstorepass "$JKS_PW" \
    -destkeystore "$WORK/keystore.jks" -deststoretype JKS -deststorepass "$JKS_PW" -destkeypass "$JKS_PW" \
    -alias "$ALIAS" -noprompt >/dev/null 2>&1 || fail "keytool import failed"
  keytool -list -v -keystore "$WORK/keystore.jks" -storepass "$JKS_PW" 2>/dev/null | grep -E 'Keystore type|Alias name|Entry type|Certificate chain length|until' | sed 's/^/  /' | tee -a "$LOG"
  unset JKS_PW; rm -f "$WORK/old.jks" "$WORK/new.p12"

  # 3. master secret JSON: same name/type/labels, origin = itself, sync marker kept,
  #    stray 'name'/'namespace' annotations and last-applied removed
  kubectl get secret "$SECRET" -n "$MASTER_NS" -o json | jq \
    --arg crt "$(b64 "$WORK/fullchain.pem")" --arg key "$(b64 "$KEY")" --arg jks "$(b64 "$WORK/keystore.jks")" '
    .metadata as $m |
    { apiVersion: "v1", kind: "Secret", type: .type,
      metadata: {
        name: $m.name, namespace: "dataos-system",
        labels: (($m.labels // {}) + {
          "caretaker.dataos.io/origin.dataplane": "hub",
          "caretaker.dataos.io/origin.name": $m.name,
          "caretaker.dataos.io/origin.namespace": "dataos-system" }),
        annotations: (($m.annotations // {})
          | del(."kubectl.kubernetes.io/last-applied-configuration", .name, .namespace)
          + { "caretaker.dataos.io/sync": "caretaker.dataos.io=sync",
              "caretaker.dataos.io/origin": ({namespace: "dataos-system", name: $m.name, uid: $m.uid, resourceVersion: $m.resourceVersion} | tojson) }) },
      data: { "tls.crt": $crt, "tls.key": $key, "keystore.jks": $jks } }' > "$WORK/master.json" || fail "jq build failed"

  # 4. copy JSON template: same as master but WITHOUT the sync marker
  jq 'del(.metadata.annotations["caretaker.dataos.io/sync"])' "$WORK/master.json" > "$WORK/copy-template.json"

  # 5. checks
  jq -r '.data["tls.crt"]' "$WORK/master.json" | base64 --decode | openssl x509 -noout -subject -serial -enddate | sed 's/^/  /' | tee -a "$LOG"
  k=$(jq -r '.data["tls.key"]' "$WORK/master.json" | base64 --decode | openssl rsa -noout -modulus 2>/dev/null | openssl md5)
  [ "$k" = "$(openssl x509 -noout -modulus -in "$CRT" | openssl md5)" ] && ok "key in secret matches cert" || fail "key mismatch in secret"
  jq '{name: .metadata.name, ns: .metadata.namespace, keys: (.data|keys), labels: .metadata.labels, annotations: .metadata.annotations}' "$WORK/master.json" | tee -a "$LOG"
  say "  copy template sync marker: $(jq -r '.metadata.annotations["caretaker.dataos.io/sync"] // "none (correct)"' "$WORK/copy-template.json")"
  kubectl replace --dry-run=server -f "$WORK/master.json" >/dev/null && ok "server dry-run OK (nothing changed)" || fail "server dry-run failed"
  say "== BUILD done. Next: backup"
}

stage_backup() {
  say "== BACKUP (read-only). Backups contain the private key - keep them safe."
  check_context
  for ns in $(namespaces); do
    kubectl get secret "$SECRET" -n "$ns" -o json > "$BACKUP/$ns.json" && ok "backed up $ns"
  done
  say "  $(ls "$BACKUP" | wc -l | tr -d ' ') files in $BACKUP"
  for d in $CARETAKER_DEPLOYS; do kubectl get deploy "$d" -n "$CARETAKER_NS" -o jsonpath='{.spec.replicas}' > "$BACKUP/replicas-$d.txt" && ok "saved replicas for $d: $(cat "$BACKUP/replicas-$d.txt")"; done
  say "== BACKUP done. Next: freeze"
}

stage_freeze() {
  say "== FREEZE caretaker sync"
  check_context
  [ -s "$WORK/master.json" ] || fail "run build first"
  ls "$BACKUP"/replicas-*.txt >/dev/null 2>&1 || fail "run backup first"
  confirm "This scales [$CARETAKER_DEPLOYS] in $CARETAKER_NS to 0."
  for d in $CARETAKER_DEPLOYS; do kubectl scale deploy "$d" -n "$CARETAKER_NS" --replicas=0 && ok "scaled $d to 0"; done
  for d in $CARETAKER_DEPLOYS; do kubectl rollout status deploy "$d" -n "$CARETAKER_NS" --timeout=180s >/dev/null 2>&1; done
  kubectl get deploy -n "$CARETAKER_NS" | sed 's/^/  /' | tee -a "$LOG"
  say "== FREEZE done. Next: master"
}

stage_master() {
  say "== MASTER: replace $SECRET in $MASTER_NS"
  check_context
  confirm "This replaces the master secret in $MASTER_NS."
  kubectl replace -f "$WORK/master.json" || fail "replace failed"
  say "  waiting 30s to make sure nothing overwrites it..."; sleep 30
  s=$(serial_in "$MASTER_NS")
  [ "$s" = "$NEW_SERIAL" ] && ok "master holds the new cert ($s)" || fail "master shows $s - something is overwriting it. STOP and investigate."
  say "== MASTER done. Next: copies"
}

stage_copies() {
  say "== COPIES: replace the copies (without sync marker)"
  check_context
  confirm "This replaces the secret in every namespace except $MASTER_NS."
  for ns in $(namespaces); do
    [ "$ns" = "$MASTER_NS" ] && continue
    jq --arg ns "$ns" '.metadata.namespace = $ns' "$WORK/copy-template.json" | kubectl replace -f - >/dev/null && ok "replaced $ns" || warn "replace failed in $ns"
  done
  say "  state of all copies:"
  show_all && ok "all namespaces hold the new cert, only $MASTER_NS has sync" || warn "some namespaces still OLD - re-run 'copies' before unfreeze"
  say "== COPIES done. Next: unfreeze"
}

stage_unfreeze() {
  say "== UNFREEZE caretaker"
  check_context
  for d in $CARETAKER_DEPLOYS; do
    r=$(cat "$BACKUP/replicas-$d.txt"); kubectl scale deploy "$d" -n "$CARETAKER_NS" --replicas="$r" && ok "scaled $d back to $r"
    kubectl rollout status deploy "$d" -n "$CARETAKER_NS" --timeout=300s
  done
  say "  waiting 120s for caretaker to sync..."; sleep 120
  show_all && ok "still all NEW after caretaker restart" || warn "something reverted - check caretaker logs before restarting workloads"
  say "== UNFREEZE done. Next: restart"
}

stage_restart() {
  say "== RESTART consumers (one at a time)"
  check_context
  confirm "This restarts 21 workloads one by one."
  echo "$RESTART_LIST" | while read -r kind nsname; do
    [ -z "$kind" ] && continue
    ns=${nsname%%/*}; name=${nsname#*/}
    say "  restarting $kind/$name in $ns"
    kubectl rollout restart "$kind/$name" -n "$ns" >/dev/null && \
    kubectl rollout status "$kind/$name" -n "$ns" --timeout=300s >/dev/null 2>&1 && ok "$ns/$name ready" || warn "$ns/$name not ready in 5 min - check it"
  done
  say "== RESTART done. Next: verify"
}

stage_verify() {
  say "== VERIFY"
  check_context
  show_all && ok "all namespaces NEW" || warn "some namespaces OLD"
  say "  live endpoint $HOST:443"
  echo | openssl s_client -connect "$HOST:443" -servername "$HOST" -showcerts 2>/dev/null | grep -E ' s:| i:' | sed 's/^/  /' | tee -a "$LOG"
  echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -serial -enddate | sed 's/^/  /' | tee -a "$LOG"
  echo | openssl s_client -connect "$HOST:443" -servername "$HOST" -CAfile "$ROOT" 2>/dev/null | grep 'Verify return code' | sed 's/^/  /' | tee -a "$LOG"
  kubectl get pods -A | grep -vE 'Running|Completed' | sed 's/^/  /' | tee -a "$LOG"
  say "== VERIFY done. Then: log in to the DataOS UI and confirm."
}

stage_rollback() {
  say "== ROLLBACK from $BACKUP"
  check_context
  confirm "This restores the OLD certificate in every namespace."
  for f in "$BACKUP"/*.json; do
    jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields)' "$f" | kubectl replace -f - >/dev/null && ok "restored $(basename "$f" .json)"
  done
  say "  then run: unfreeze (if frozen), restart"
}

case "${1:-}" in
  preflight|build|backup|freeze|master|copies|unfreeze|restart|verify|rollback) "stage_$1" ;;
  *) sed -n '3,20p' "$0"; exit 1 ;;
esac
