import hashlib
import io
import os
import pytest
from src import file_move as app_module
from src.file_move import app


@pytest.fixture()
def client(tmp_path, monkeypatch):
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    (src_dir / "upload_index.html").write_text(
        "<h3>Test File Transfer API</h3>", encoding="utf-8"
    )

    dest_dir = tmp_path / "dest"
    dest_dir.mkdir()

    monkeypatch.setenv("FILE_TRANSFER_BASE_DIR", str(tmp_path))
    monkeypatch.setattr(app_module, "src_dir", str(src_dir))
    monkeypatch.setattr(app_module, "dest_dir", str(dest_dir))

    app.config["TESTING"] = True
    with app.test_client() as test_client:
        yield test_client


def test_get_upload_ui(client):
    res = client.get("/")
    assert res.status_code == 200
    assert b"Test File Transfer API" in res.data


def test_transfer_file_and_verify_sha256(client):
    payload = b"chunked transfer payload for sha256 check"
    expected_hash = hashlib.sha256(payload).hexdigest()

    data = {"file": (io.BytesIO(payload), "sample.txt")}
    res = client.post("/transfer", data=data, content_type="multipart/form-data")

    assert res.status_code == 200
    body = res.get_json()
    assert body["sha256"] == expected_hash
    assert os.path.exists(body["saved_as"])
