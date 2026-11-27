import hashlib
import os
from flask import Flask,jsonify,request,send_from_directory
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

CHUNK_SIZE = 65536

default_base_dir=os.path.dirname(os.path.abspath(__file__))
base_dir=os.environ.get("FILE_TRANSFER_BASE_DIR",default_base_dir)
src_dir=os.path.join(base_dir,"src")
dest_dir=os.path.join(base_dir,"dest")

os.makedirs(dest_dir, exist_ok=True)
os.makedirs(src_dir,exist_ok=True)

@app.route("/",methods=["GET"])
def server_upload_ui():
    return send_from_directory(src_dir,"upload_index.html")

@app.route("/transfer", methods=["POST"])
def transfer_file():
    if "file" not in request.files:
        return jsonify({"error": "No file part in the request"}), 400
    
    upload_file = request.files["file"]

    if upload_file.filename == "":
        return jsonify({"error": "No file selected"}), 400
    
    safe_name = os.path.basename(upload_file.filename)
    dest_path = os.path.join(dest_dir,safe_name)

    hasher = hashlib.sha256()

    with open(dest_path,"wb") as dst:
        while True:
            chunk = upload_file.stream.read(CHUNK_SIZE)
            if not chunk:
                break
            dst.write(chunk)
            hasher.update(chunk)
    
    file_hash = hasher.hexdigest()

    return jsonify({
        "message": "File transferred successfully",
        "saved_as": dest_path,
        "sha256": file_hash
    }), 200

if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host=host, port=port, debug=debug)
            
