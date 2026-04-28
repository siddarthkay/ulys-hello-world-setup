import os, hmac, hashlib
from flask import Flask, request, jsonify, abort

app = Flask(__name__)
SECRET = os.environ["WORKER_SECRET"].encode()

def verify():
    sig = request.headers.get("X-Signature", "")
    expected = hmac.new(SECRET, request.get_data(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        abort(401)

@app.post("/ready")
def ready():
    verify()
    return jsonify(ok=True)

@app.post("/transform")
def transform():
    verify()
    data = request.get_json(force=True)
    n = int(data.get("n", 0))
    return jsonify(transformed=n * 2 + 1, source="worker")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8081)))
