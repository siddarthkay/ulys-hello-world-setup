import os
from flask import Flask, request, jsonify, abort
from google.oauth2 import id_token
from google.auth.transport import requests as g_requests

app = Flask(__name__)
EXPECTED_INVOKER_EMAIL = os.environ["EXPECTED_INVOKER_EMAIL"]


def verify():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        abort(401)
    token = auth[7:]
    # Audience: the URL the request was made to. Cloud Run sets the Host
    # header to the public service URL; we accept tokens whose `aud` matches.
    expected_audience = f"https://{request.host}"
    try:
        info = id_token.verify_oauth2_token(token, g_requests.Request(), audience=expected_audience)
    except ValueError:
        abort(401)
    if info.get("email") != EXPECTED_INVOKER_EMAIL:
        abort(403)


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
