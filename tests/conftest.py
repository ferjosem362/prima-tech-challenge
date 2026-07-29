"""Pytest fixtures.

The whole AWS layer is emulated in-process with ``moto``: the tests exercise
the *real* boto3 calls (including the ConditionExpression that enforces email
uniqueness) without a network round-trip and without mocking our own code.
"""

from __future__ import annotations

from collections.abc import Iterator

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

TABLE = "users-test"
BUCKET = "prima-tech-challenge-test"
REGION = "us-east-1"

# A minimal but genuinely valid 1x1 PNG (header + IHDR + IDAT + IEND).
PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000a49444154789c6360000002000100ffff0300000600"
    "0557bfabd40000000049454e44ae426082"
)


@pytest.fixture(autouse=True)
def aws_environment(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Fake credentials + test resource names, isolated per test."""
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SECURITY_TOKEN": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": REGION,
        "AWS_REGION": REGION,
        "DYNAMODB_TABLE": TABLE,
        "S3_BUCKET": BUCKET,
        "ENVIRONMENT": "test",
    }.items():
        monkeypatch.setenv(key, value)
    # moto intercepts the real AWS endpoints, so there must be no override at
    # all — not even an empty one, which boto3 would reject as invalid.
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)

    # Settings and boto3 clients are cached singletons: reset them so each test
    # picks up this environment instead of a previous one.
    from app.core.config import Settings, get_settings
    from app.infrastructure.aws import reset_clients

    # A developer's local .env must never leak in: it would silently point the
    # suite at LocalStack instead of moto, so the tests would pass or fail
    # depending on whether a container happens to be running.
    monkeypatch.setitem(Settings.model_config, "env_file", None)

    get_settings.cache_clear()
    reset_clients()
    reset_clients()
    yield
    get_settings.cache_clear()
    reset_clients()


@pytest.fixture()
def aws(aws_environment: None) -> Iterator[dict[str, object]]:
    """Provision an empty DynamoDB table and S3 bucket inside moto."""
    with mock_aws():
        dynamodb = boto3.client("dynamodb", region_name=REGION)
        dynamodb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "email", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "email", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket=BUCKET)
        yield {"dynamodb": dynamodb, "s3": s3}


@pytest.fixture()
def client(aws: dict[str, object]) -> Iterator[TestClient]:
    """A TestClient wired against the mocked AWS backends."""
    from app.main import create_app

    with TestClient(create_app()) as test_client:
        yield test_client


def avatar(name: str = "avatar.png", data: bytes = PNG_1PX, mime: str = "image/png"):
    """Helper building the multipart file tuple."""
    return {"avatar": (name, data, mime)}
