"""boto3 client factory.

Clients are expensive to build (they parse a JSON service model) and are
thread-safe once created, so we build exactly one per service and reuse it for
the whole process lifetime.
"""

from __future__ import annotations

from functools import lru_cache
from typing import cast

import boto3
from botocore.client import BaseClient
from botocore.config import Config

from app.core.config import get_settings


def _client_config() -> Config:
    """Sane, production-oriented botocore defaults."""
    settings = get_settings()
    return Config(
        region_name=settings.aws_region,
        # Adaptive mode adds client-side rate limiting on top of retries, which
        # is what you want against a throttling-prone service like DynamoDB.
        retries={"max_attempts": 5, "mode": "adaptive"},
        connect_timeout=3,
        read_timeout=10,
        # The default pool of 10 would become the bottleneck under concurrency.
        max_pool_connections=50,
        user_agent_extra=f"{settings.app_name}/{settings.app_version}",
    )


@lru_cache(maxsize=1)
def get_dynamodb_client() -> BaseClient:
    """Low-level DynamoDB client.

    We use the *client* (not the resource) on purpose: it speaks the native
    AttributeValue wire format (``{"S": "..."}``), which is exactly the item
    shape the challenge expects to see stored in the table.
    """
    settings = get_settings()
    # botocore builds clients dynamically from a JSON service model, so boto3
    # can only type this as Any. The cast is where we take responsibility for
    # the narrowing instead of letting Any leak through the whole call chain.
    return cast(
        BaseClient,
        boto3.client("dynamodb", endpoint_url=settings.aws_endpoint_url, config=_client_config()),
    )


@lru_cache(maxsize=1)
def get_s3_client() -> BaseClient:
    """Low-level S3 client."""
    settings = get_settings()
    return cast(
        BaseClient,
        boto3.client("s3", endpoint_url=settings.aws_endpoint_url, config=_client_config()),
    )


def reset_clients() -> None:
    """Drop cached clients (used by the test-suite between fixtures)."""
    get_dynamodb_client.cache_clear()
    get_s3_client.cache_clear()
