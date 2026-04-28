import os, time, hmac, hashlib, json, datetime, uuid
from flask import Flask, jsonify, request
import psycopg2, redis, requests

app = Flask(__name__)

DB_DSN = os.environ["DATABASE_URL"]
REDIS_URL = os.environ["REDIS_URL"]
WORKER_URL = os.environ["WORKER_URL"]
WORKER_SECRET = os.environ["WORKER_SECRET"].encode()
GIT_SHA = os.environ.get("GIT_SHA", "unknown")
BUILD_TIME = os.environ.get("BUILD_TIME", "unknown")

def sign(body: bytes) -> str:
    return hmac.new(WORKER_SECRET, body, hashlib.sha256).hexdigest()

def db():
    return psycopg2.connect(DB_DSN, connect_timeout=2)

def rds():
    return redis.from_url(REDIS_URL, socket_connect_timeout=2, socket_timeout=2)

def ensure_schema():
    with db() as c, c.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload JSONB, result JSONB, created_at TIMESTAMP)")

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
        body = b'{"ping":1}'
        r = requests.post(f"{WORKER_URL}/ready",
                          headers={"X-Signature": sign(body), "Content-Type": "application/json"},
                          data=body, timeout=2)
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
    body = json.dumps(payload).encode()
    r = requests.post(f"{WORKER_URL}/transform",
                      headers={"X-Signature": sign(body), "Content-Type": "application/json"},
                      data=body, timeout=5)
    r.raise_for_status()
    transformed = r.json()
    ensure_schema()
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO jobs (id, payload, result, created_at) VALUES (%s, %s, %s, %s)",
                    (job_id, json.dumps(payload), json.dumps(transformed), datetime.datetime.utcnow()))
    rds().setex(f"job:{job_id}", 300, json.dumps(transformed))
    return jsonify(job_id=job_id, payload=payload, result=transformed, cached_for_seconds=300)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
