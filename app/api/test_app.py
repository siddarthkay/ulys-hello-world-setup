import os, json
import pytest
from unittest.mock import MagicMock, patch

os.environ.setdefault("DATABASE_URL", "postgres://x:y@h:5432/d")
os.environ.setdefault("REDIS_URL", "redis://h:6379/0")
os.environ.setdefault("WORKER_URL", "http://worker:8081")
os.environ.setdefault("WORKER_SECRET", "s3cret")

import app  # noqa: E402


@pytest.fixture
def client():
    return app.app.test_client()


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.data == b"ok"


def test_version(client):
    r = client.get("/version")
    assert r.status_code == 200
    body = r.get_json()
    assert "git_sha" in body and "build_time" in body


def test_sign_is_deterministic_hmac():
    a = app.sign(b'{"x":1}')
    b = app.sign(b'{"x":1}')
    assert a == b
    assert app.sign(b'{"x":1}') != app.sign(b'{"x":2}')


def test_readyz_all_ok(client, monkeypatch):
    fake_cur = MagicMock()
    fake_cur.fetchone.return_value = (1,)
    fake_conn = MagicMock()
    fake_conn.__enter__.return_value = fake_conn
    fake_conn.cursor.return_value.__enter__.return_value = fake_cur
    monkeypatch.setattr(app, "db", lambda: fake_conn)

    fake_rds = MagicMock(); fake_rds.ping.return_value = True
    monkeypatch.setattr(app, "rds", lambda: fake_rds)

    fake_resp = MagicMock(); fake_resp.status_code = 200
    monkeypatch.setattr(app.requests, "post", lambda *a, **k: fake_resp)

    r = client.get("/readyz")
    assert r.status_code == 200
    body = r.get_json()
    assert body == {"db": "ok", "redis": "ok", "worker": "ok"}


def test_readyz_db_failure_returns_503(client, monkeypatch):
    def raise_db(): raise RuntimeError("connection refused")
    monkeypatch.setattr(app, "db", raise_db)

    fake_rds = MagicMock(); fake_rds.ping.return_value = True
    monkeypatch.setattr(app, "rds", lambda: fake_rds)

    fake_resp = MagicMock(); fake_resp.status_code = 200
    monkeypatch.setattr(app.requests, "post", lambda *a, **k: fake_resp)

    r = client.get("/readyz")
    assert r.status_code == 503
    body = r.get_json()
    assert body["db"].startswith("fail")
    assert body["redis"] == "ok"
    assert body["worker"] == "ok"


def test_readyz_worker_non_200_marked_fail(client, monkeypatch):
    fake_cur = MagicMock(); fake_cur.fetchone.return_value = (1,)
    fake_conn = MagicMock()
    fake_conn.__enter__.return_value = fake_conn
    fake_conn.cursor.return_value.__enter__.return_value = fake_cur
    monkeypatch.setattr(app, "db", lambda: fake_conn)

    monkeypatch.setattr(app, "rds", lambda: MagicMock(ping=lambda: True))

    fake_resp = MagicMock(); fake_resp.status_code = 401
    monkeypatch.setattr(app.requests, "post", lambda *a, **k: fake_resp)

    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.get_json()["worker"].startswith("fail")
