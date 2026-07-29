"""Application services (use cases).

This layer owns the orchestration and the business rules.  It talks only to the
ports declared in :mod:`app.domain.ports`, so it can be unit-tested against
in-memory fakes and would survive a migration away from AWS untouched.
"""

from __future__ import annotations

import logging
from uuid import uuid4

from fastapi import UploadFile

from app.core.config import Settings
from app.core.errors import UnsupportedAvatarTypeError
from app.domain.models import Page, User
from app.domain.ports import AvatarStorage, UserRepository
from app.services.images import read_limited, sniff_image

logger = logging.getLogger(__name__)


class UserService:
    """Use cases around user registration and listing."""

    def __init__(
        self,
        repository: UserRepository,
        storage: AvatarStorage,
        settings: Settings,
    ) -> None:
        self._repository = repository
        self._storage = storage
        self._settings = settings

    async def list_users(self, limit: int, cursor: str | None = None) -> Page:
        """Return one page of registered users."""
        return await self._repository.list_users(limit=limit, cursor=cursor)

    async def register_user(self, name: str, email: str, avatar: UploadFile) -> User:
        """Create a user: validate + store the avatar, then persist the record.

        The two writes (S3, DynamoDB) cannot be made atomic, so we order them
        so that the failure modes are benign, and we compensate:

        1. Upload the avatar first. If DynamoDB then rejects the write we delete
           the object again, leaving no dangling reference in the database.
        2. Persist the item with a conditional write, which is what actually
           enforces email uniqueness.

        The worst case is a short-lived orphan object in S3 (harmless, and
        reaped by a lifecycle rule) rather than a user row pointing at a
        non-existent image.
        """
        payload = await read_limited(avatar, self._settings.max_avatar_bytes)

        kind = sniff_image(payload)
        if kind is None:
            raise UnsupportedAvatarTypeError(
                "The avatar must be a real PNG, JPEG, GIF or WebP image."
            )
        if kind.media_type not in self._settings.allowed_avatar_types:
            raise UnsupportedAvatarTypeError(
                f"Media type '{kind.media_type}' is not accepted. Allowed: "
                + ", ".join(sorted(self._settings.allowed_avatar_types))
            )

        # A random key, never the user's email or original filename: object keys
        # end up in public URLs and access logs, so they must not carry PII, and
        # a client-supplied name would open the door to path traversal and to
        # overwriting somebody else's avatar.
        key = f"{self._settings.s3_avatar_prefix}/{uuid4().hex}{kind.extension}"

        avatar_url = await self._storage.upload(key, payload, kind.media_type)
        user = User(name=name, email=email, avatar_url=avatar_url)

        try:
            await self._repository.create(user)
        except Exception:
            await self._storage.delete(key)  # compensating action
            raise

        logger.info("user_registered", extra={"s3_key": key})
        return user

    async def healthcheck(self) -> None:
        """Verify that both downstream dependencies answer."""
        await self._repository.healthcheck()
        await self._storage.healthcheck()
