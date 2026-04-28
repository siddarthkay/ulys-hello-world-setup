import os, time, json, datetime, uuid
from flask import Flask, jsonify
import psycopg2, redis, requests
from google.oauth2 import id_token
from google.auth.transport import requests as g_requests

app = Flask(__name__)

DB_HOST = os.environ["DB_HOST"]
DB_USER = os.environ["DB_USER"]
DB_NAME = os.environ["DB_NAME"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))
WORKER_URL = os.environ["WORKER_URL"]
GIT_SHA = os.environ.get("GIT_SHA", "unknown")
BUILD_TIME = os.environ.get("BUILD_TIME", "unknown")

DB_DSN = f"host={DB_HOST} port=5432 user={DB_USER} password={DB_PASSWORD} dbname={DB_NAME} connect_timeout=2"

def db():
    return psycopg2.connect(DB_DSN)

def rds():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_connect_timeout=2, socket_timeout=2)

def worker_token():
    # Cloud Run's metadata server mints an ID token with `aud` set to the
    # worker URL. The worker verifies signature + audience + email claim.
    return id_token.fetch_id_token(g_requests.Request(), WORKER_URL)

def call_worker(path, payload):
    body = json.dumps(payload).encode()
    return requests.post(
        f"{WORKER_URL}{path}",
        headers={
            "Authorization": f"Bearer {worker_token()}",
            "Content-Type": "application/json",
        },
        data=body,
        timeout=5,
    )

def ensure_schema():
    with db() as c, c.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS jobs ("
            "id TEXT PRIMARY KEY, payload JSONB, result JSONB, created_at TIMESTAMP)"
        )

@app.get("/healthz")
def healthz():
    return "ok", 200

@app.get("/readyz")
def readyz():
    checks = {}
    try:
        with db() as c, c.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        checks["db"] = "ok"
    except Exception as e:
        checks["db"] = f"fail: {e}"
    try:
        rds().ping()
        checks["redis"] = "ok"
    except Exception as e:
        checks["redis"] = f"fail: {e}"
    try:
        r = call_worker("/ready", {"ping": 1})
        checks["worker"] = "ok" if r.status_code == 200 else f"fail: status {r.status_code}"
    except Exception as e:
        checks["worker"] = f"fail: {e}"
    ok = all(v == "ok" for v in checks.values())
    return jsonify(checks), (200 if ok else 503)

@app.get("/version")
def version():
    return jsonify(git_sha=GIT_SHA, build_time=BUILD_TIME)

@app.get("/work")
def work():
    job_id = str(uuid.uuid4())
    payload = {"job_id": job_id, "n": int(time.time())}
    r = call_worker("/transform", payload)
    r.raise_for_status()
    transformed = r.json()
    ensure_schema()
    with db() as c, c.cursor() as cur:
        cur.execute(
            "INSERT INTO jobs (id, payload, result, created_at) VALUES (%s, %s, %s, %s)",
            (job_id, json.dumps(payload), json.dumps(transformed), datetime.datetime.utcnow()),
        )
    rds().setex(f"job:{job_id}", 300, json.dumps(transformed))
    return jsonify(job_id=job_id, payload=payload, result=transformed, cached_for_seconds=300)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
