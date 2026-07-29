"""Error paths: every one of them must return problem+json, never a traceback."""

from __future__ import annotations

from tests.conftest import BUCKET, avatar


def _assert_problem(response, status: int, code: str) -> None:
    assert response.status_code == status
    assert response.headers["content-type"].startswith("application/problem+json")
    body = response.json()
    assert body["code"] == code
    assert body["status"] == status
    assert body["request_id"]


def test_duplicate_email_is_rejected_with_409(client) -> None:
    payload = {"name": "Test User", "email": "test-user@prima.it"}
    assert client.post("/user", data=payload, files=avatar()).status_code == 201

    _assert_problem(
        client.post("/user", data=payload, files=avatar()),
        409,
        "user_already_exists",
    )


def test_duplicate_email_does_not_leave_an_orphan_object(client, aws) -> None:
    """The compensating delete must clean up the avatar of the rejected write."""
    payload = {"name": "Test User", "email": "test-user@prima.it"}
    client.post("/user", data=payload, files=avatar())
    client.post("/user", data=payload, files=avatar())

    objects = aws["s3"].list_objects_v2(Bucket=BUCKET).get("Contents", [])
    assert len(objects) == 1  # only the avatar of the successful registration


def test_invalid_email_is_rejected_with_400(client) -> None:
    _assert_problem(
        client.post("/user", data={"name": "Test User", "email": "not-an-email"}, files=avatar()),
        400,
        "validation_failed",
    )


def test_blank_name_is_rejected_with_400(client) -> None:
    _assert_problem(
        client.post("/user", data={"name": "   ", "email": "a@prima.it"}, files=avatar()),
        400,
        "validation_failed",
    )


def test_missing_avatar_is_rejected_with_400(client) -> None:
    _assert_problem(
        client.post("/user", data={"name": "Test User", "email": "a@prima.it"}),
        400,
        "validation_failed",
    )


def test_a_disguised_non_image_is_rejected_with_415(client) -> None:
    """Content-Type says PNG but the bytes are not: magic-byte sniffing wins."""
    _assert_problem(
        client.post(
            "/user",
            data={"name": "Test User", "email": "a@prima.it"},
            files=avatar(data=b"#!/bin/sh\nrm -rf /\n"),
        ),
        415,
        "unsupported_avatar_type",
    )


def test_oversized_avatar_is_rejected_with_413(aws, monkeypatch) -> None:
    """The limit is enforced while streaming, before anything reaches S3.

    Settings is a frozen model whose values live on the instance, so the limit
    has to be lowered the way production would set it — through the
    environment — and the app rebuilt so it picks the new value up.
    """
    from fastapi.testclient import TestClient

    from app.core.config import get_settings
    from app.main import create_app

    monkeypatch.setenv("MAX_AVATAR_BYTES", "128")
    get_settings.cache_clear()

    with TestClient(create_app()) as client:
        response = client.post(
            "/user",
            data={"name": "Test User", "email": "a@prima.it"},
            files=avatar(data=b"\x89PNG\r\n\x1a\n" + b"\x00" * 4096),
        )

    _assert_problem(response, 413, "avatar_too_large")

    # Nothing was uploaded: the guard rail runs before the storage call.
    assert aws["s3"].list_objects_v2(Bucket=BUCKET).get("Contents", []) == []


def test_malformed_cursor_is_rejected_with_400(client) -> None:
    _assert_problem(
        client.get("/users", params={"cursor": "!!not-base64!!"}), 400, "invalid_cursor"
    )


def test_readiness_reports_a_missing_table(client, aws) -> None:
    from tests.conftest import TABLE

    aws["dynamodb"].delete_table(TableName=TABLE)
    _assert_problem(client.get("/health/ready"), 503, "repository_unavailable")
