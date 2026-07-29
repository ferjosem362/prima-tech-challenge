"""Ports (hexagonal architecture).

The service layer depends on these Protocols, never on concrete AWS adapters.
Swapping DynamoDB for Postgres, or S3 for MinIO, is a matter of writing a new
adapter; and tests can inject in-memory fakes with zero mocking machinery.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.domain.models import Page, User


@runtime_checkable
class UserRepository(Protocol):
    """Persistence port for :class:`~app.domain.models.User`."""

    async def create(self, user: User) -> None:
        """Persist a new user.

        Raises:
            UserAlreadyExistsError: if the email is already registered.
            RepositoryError: on any other backend failure.
        """

    async def list_users(self, limit: int, cursor: str | None = None) -> Page:
        """Return one page of users."""

    async def healthcheck(self) -> None:
        """Raise RepositoryError if the backing store is not reachable."""


@runtime_checkable
class AvatarStorage(Protocol):
    """Object storage port for avatar images."""

    async def upload(self, key: str, payload: bytes, content_type: str) -> str:
        """Store ``payload`` under ``key`` and return its public URL."""

    async def delete(self, key: str) -> None:
        """Best-effort removal, used as a compensating action."""

    async def healthcheck(self) -> None:
        """Raise StorageError if the bucket is not reachable."""
