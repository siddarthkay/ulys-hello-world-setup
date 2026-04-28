import os
import pytest
from unittest.mock import patch

os.environ.setdefault("EXPECTED_INVOKER_EMAIL", "ulys-api@example.iam.gserviceaccount.com")

import app  # noqa: E402


@pytest.fixture
def client():
    return app.app.test_client()


def _good_token_info():
    return {"email": os.environ["EXPECTED_INVOKER_EMAIL"], "aud": "https://localhost"}


def test_ready_with_valid_token(client):
    with patch("app.id_token.verify_oauth2_token", return_value=_good_token_info()):
        r = client.post("/ready", json={"ping": 1},
                        headers={"Authorization": "Bearer faketoken"})
    assert r.status_code == 200
    assert r.get_json() == {"ok": True}


def test_ready_rejects_missing_authorization_header(client):
    r = client.post("/ready", json={"ping": 1})
    assert r.status_code == 401


def test_ready_rejects_non_bearer_scheme(client):
    r = client.post("/ready", json={"ping": 1},
                    headers={"Authorization": "Basic abc"})
    assert r.status_code == 401


def test_ready_rejects_invalid_token(client):
    with patch("app.id_token.verify_oauth2_token", side_effect=ValueError("bad sig")):
        r = client.post("/ready", json={"ping": 1},
                        headers={"Authorization": "Bearer faketoken"})
    assert r.status_code == 401


def test_ready_rejects_wrong_invoker_email(client):
    info = _good_token_info()
    info["email"] = "someone-else@evil.iam.gserviceaccount.com"
    with patch("app.id_token.verify_oauth2_token", return_value=info):
        r = client.post("/ready", json={"ping": 1},
                        headers={"Authorization": "Bearer faketoken"})
    assert r.status_code == 403


def test_transform_doubles_plus_one(client):
    with patch("app.id_token.verify_oauth2_token", return_value=_good_token_info()):
        r = client.post("/transform", json={"n": 7},
                        headers={"Authorization": "Bearer faketoken"})
    assert r.status_code == 200
    assert r.get_json() == {"transformed": 15, "source": "worker"}


def test_transform_rejects_unauthenticated(client):
    r = client.post("/transform", json={"n": 7})
    assert r.status_code == 401
