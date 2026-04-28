import os
import pytest
from unittest.mock import MagicMock

os.environ.setdefault("DB_HOST", "10.0.0.1")
os.environ.setdefault("DB_USER", "app")
os.environ.setdefault("DB_NAME", "app")
os.environ.setdefault("DB_PASSWORD", "x")
os.environ.setdefault("REDIS_HOST", "10.0.0.2")
os.environ.setdefault("REDIS_PORT", "6379")
os.environ.setdefault("WORKER_URL", "https://worker.example.run.app")

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
    monkeypatch.setattr(app, "call_worker", lambda *a, **k: fake_resp)

    r = client.get("/readyz")
    assert r.status_code == 200
    body = r.get_json()
    assert body == {"db": "ok", "redis": "ok", "worker": "ok"}


def test_readyz_db_failure_returns_503(client, monkeypatch):
    def raise_db():
        raise RuntimeError("connection refused")

    monkeypatch.setattr(app, "db", raise_db)
    monkeypatch.setattr(app, "rds", lambda: MagicMock(ping=lambda: True))
    fake_resp = MagicMock(); fake_resp.status_code = 200
    monkeypatch.setattr(app, "call_worker", lambda *a, **k: fake_resp)

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
    monkeypatch.setattr(app, "call_worker", lambda *a, **k: fake_resp)

    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.get_json()["worker"].startswith("fail")
