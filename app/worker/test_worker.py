import os, hmac, hashlib
import pytest

os.environ.setdefault("WORKER_SECRET", "s3cret")

import app  # noqa: E402


@pytest.fixture
def client():
    return app.app.test_client()


def sig(body: bytes, secret: bytes = b"s3cret") -> str:
    return hmac.new(secret, body, hashlib.sha256).hexdigest()


def test_ready_with_valid_signature(client):
    body = b'{"ping":1}'
    r = client.post("/ready", data=body, headers={
        "X-Signature": sig(body),
        "Content-Type": "application/json",
    })
    assert r.status_code == 200
    assert r.get_json() == {"ok": True}


def test_ready_rejects_bad_signature(client):
    r = client.post("/ready", data=b'{"ping":1}', headers={
        "X-Signature": "deadbeef",
        "Content-Type": "application/json",
    })
    assert r.status_code == 401


def test_ready_rejects_missing_signature(client):
    r = client.post("/ready", data=b'{"ping":1}',
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 401


def test_transform_doubles_plus_one(client):
    body = b'{"n": 7}'
    r = client.post("/transform", data=body, headers={
        "X-Signature": sig(body),
        "Content-Type": "application/json",
    })
    assert r.status_code == 200
    assert r.get_json() == {"transformed": 15, "source": "worker"}


def test_transform_rejects_unsigned(client):
    r = client.post("/transform", data=b'{"n":7}',
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 401


def test_transform_rejects_signature_for_different_body(client):
    r = client.post("/transform", data=b'{"n":7}', headers={
        "X-Signature": sig(b'{"n":99}'),
        "Content-Type": "application/json",
    })
    assert r.status_code == 401
