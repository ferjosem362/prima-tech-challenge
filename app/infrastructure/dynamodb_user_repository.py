"""DynamoDB adapter for the UserRepository port."""

from __future__ import annotations

import base64
import binascii
import json
import logging
from typing import Any, cast

from botocore.exceptions import BotoCoreError, ClientError

from app.core.concurrency import run_blocking
from app.core.config import Settings
from app.core.errors import (
    InvalidCursorError,
    RepositoryError,
    UserAlreadyExistsError,
)
from app.domain.models import Page, User

logger = logging.getLogger(__name__)


def _encode_cursor(last_key: dict[str, Any]) -> str:
    """Turn a DynamoDB LastEvaluatedKey into an opaque, URL-safe token.

    Clients must treat it as a black box; encoding it keeps the internal key
    schema out of our public API contract.
    """
    raw = json.dumps(last_key, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str) -> dict[str, Any]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        return cast(dict[str, Any], json.loads(base64.urlsafe_b64decode(padded)))
    except (binascii.Error, ValueError, UnicodeDecodeError) as exc:
        raise InvalidCursorError("The supplied cursor is not a valid token.") from exc


class DynamoDBUserRepository:
    """Stores users as items keyed by ``email``.

    Item layout (native AttributeValue format)::

        {"name": {"S": "..."}, "email": {"S": "..."}, "avatar_url": {"S": "..."}}
    """

    def __init__(self, client: Any, settings: Settings) -> None:
        self._client = client
        self._table = settings.dynamodb_table
        self._pk = settings.dynamodb_partition_key

    # -- mapping ----------------------------------------------------------
    @staticmethod
    def _to_item(user: User) -> dict[str, dict[str, str]]:
        return {
            "name": {"S": user.name},
            "email": {"S": user.email},
            "avatar_url": {"S": user.avatar_url},
        }

    @staticmethod
    def _to_user(item: dict[str, dict[str, str]]) -> User:
        # ``.get(...)`` guards against legacy items written without every field.
        return User(
            name=item.get("name", {}).get("S", ""),
            email=item.get("email", {}).get("S", ""),
            avatar_url=item.get("avatar_url", {}).get("S", ""),
        )

    # -- port implementation ----------------------------------------------
    async def create(self, user: User) -> None:
        try:
            await run_blocking(
                self._client.put_item,
                TableName=self._table,
                Item=self._to_item(user),
                # Atomic uniqueness check: DynamoDB refuses the write if an item
                # with the same partition key already exists. No read-then-write
                # race window, unlike a get_item + put_item pair.
                ConditionExpression=f"attribute_not_exists({self._pk})",
            )
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code == "ConditionalCheckFailedException":
                raise UserAlreadyExistsError(
                    "A user with this email address is already registered."
                ) from exc
            logger.error("dynamodb_put_failed", extra={"aws_error_code": code})
            raise RepositoryError("Could not persist the user.") from exc
        except BotoCoreError as exc:  # network/credential level failures
            logger.error("dynamodb_unreachable")
            raise RepositoryError("Could not reach the database.") from exc

    async def list_users(self, limit: int, cursor: str | None = None) -> Page:
        params: dict[str, Any] = {"TableName": self._table, "Limit": limit}
        if cursor:
            params["ExclusiveStartKey"] = _decode_cursor(cursor)

        try:
            # NOTE: Scan is acceptable here because "list every user" has no
            # partition key to query on. It is O(table): at real scale this
            # endpoint would be backed by a GSI with a bucketed partition key,
            # or by a projection kept in OpenSearch. Pagination is already in
            # place so the API contract would not change.
            response = await run_blocking(self._client.scan, **params)
        except (ClientError, BotoCoreError) as exc:
            logger.error("dynamodb_scan_failed")
            raise RepositoryError("Could not read the user list.") from exc

        users = [self._to_user(item) for item in response.get("Items", [])]
        last_key = response.get("LastEvaluatedKey")
        return Page(items=users, next_cursor=_encode_cursor(last_key) if last_key else None)

    async def healthcheck(self) -> None:
        try:
            await run_blocking(self._client.describe_table, TableName=self._table)
        except (ClientError, BotoCoreError) as exc:
            raise RepositoryError(f"Table '{self._table}' is not available.") from exc
