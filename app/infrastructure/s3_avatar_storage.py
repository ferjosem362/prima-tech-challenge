"""S3 adapter for the AvatarStorage port."""

from __future__ import annotations

import logging
from typing import Any

from botocore.exceptions import BotoCoreError, ClientError

from app.core.concurrency import run_blocking
from app.core.config import Settings
from app.core.errors import StorageError

logger = logging.getLogger(__name__)


class S3AvatarStorage:
    """Uploads avatars to an S3 bucket and exposes their public URL."""

    def __init__(self, client: Any, settings: Settings) -> None:
        self._client = client
        self._settings = settings
        self._bucket = settings.s3_bucket

    async def upload(self, key: str, payload: bytes, content_type: str) -> str:
        extra: dict[str, Any] = {
            "ContentType": content_type,
            # Avatars are immutable (the key contains a UUID), so we can let
            # browsers and CDNs cache them forever.
            "CacheControl": "public, max-age=31536000, immutable",
        }
        if self._settings.s3_server_side_encryption:
            extra["ServerSideEncryption"] = self._settings.s3_server_side_encryption

        try:
            await run_blocking(
                self._client.put_object,
                Bucket=self._bucket,
                Key=key,
                Body=payload,
                **extra,
            )
        except (ClientError, BotoCoreError) as exc:
            logger.error("s3_put_failed", extra={"s3_key": key})
            raise StorageError("Could not store the avatar image.") from exc

        logger.info("avatar_uploaded", extra={"s3_key": key, "bytes": len(payload)})
        return self._settings.object_url(key)

    async def delete(self, key: str) -> None:
        """Compensating action: never let a failure here mask the real error."""
        try:
            await run_blocking(self._client.delete_object, Bucket=self._bucket, Key=key)
            logger.info("avatar_rolled_back", extra={"s3_key": key})
        except (ClientError, BotoCoreError):
            # An orphan object is a minor, sweepable problem (an S3 lifecycle
            # rule on the prefix cleans it up); losing the original exception
            # would be much worse for debugging.
            logger.warning("avatar_rollback_failed", extra={"s3_key": key})

    async def healthcheck(self) -> None:
        try:
            await run_blocking(self._client.head_bucket, Bucket=self._bucket)
        except (ClientError, BotoCoreError) as exc:
            raise StorageError(f"Bucket '{self._bucket}' is not available.") from exc
