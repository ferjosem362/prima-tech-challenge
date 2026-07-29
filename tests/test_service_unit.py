"""Unit tests of the service layer against in-memory fakes.

No AWS, no HTTP: this is where the orchestration rules (ordering of writes,
compensating delete) are pinned down cheaply and deterministically.
"""

from __future__ import annotations

import io

import pytest
from fastapi import UploadFile

from app.core.config import Settings
from app.core.errors import RepositoryError, UnsupportedAvatarTypeError
from app.domain.models import Page, User
from app.services.user_service import UserService
from tests.conftest import PNG_1PX


class InMemoryRepository:
    """Fake UserRepository; can be told to blow up on the next write."""

    def __init__(self, fail: Exception | None = None) -> None:
        self.users: list[User] = []
        self.fail = fail

    async def create(self, user: User) -> None:
        if self.fail:
            raise self.fail
        self.users.append(user)

    async def list_users(self, limit: int, cursor: str | None = None) -> Page:
        return Page(items=self.users[:limit])

    async def healthcheck(self) -> None: ...


class InMemoryStorage:
    """Fake AvatarStorage recording uploads and deletions."""

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.deleted: list[str] = []

    async def upload(self, key: str, payload: bytes, content_type: str) -> str:
        self.objects[key] = payload
        return f"https://cdn.example.test/{key}"

    async def delete(self, key: str) -> None:
        self.deleted.append(key)
        self.objects.pop(key, None)

    async def healthcheck(self) -> None: ...


def _upload(data: bytes = PNG_1PX) -> UploadFile:
    return UploadFile(filename="avatar.png", file=io.BytesIO(data))


def _service(repository, storage) -> UserService:
    return UserService(repository, storage, Settings(s3_bucket="unit-test"))


@pytest.mark.anyio
async def test_avatar_is_uploaded_before_the_user_is_persisted() -> None:
    repository, storage = InMemoryRepository(), InMemoryStorage()

    user = await _service(repository, storage).register_user(
        "Test User", "test-user@prima.it", _upload()
    )

    assert len(storage.objects) == 1
    assert repository.users == [user]
    assert user.avatar_url.endswith(".png")


@pytest.mark.anyio
async def test_repository_failure_triggers_the_compensating_delete() -> None:
    repository = InMemoryRepository(fail=RepositoryError("boom"))
    storage = InMemoryStorage()

    with pytest.raises(RepositoryError):
        await _service(repository, storage).register_user(
            "Test User", "test-user@prima.it", _upload()
        )

    assert storage.objects == {}  # no orphan left behind
    assert len(storage.deleted) == 1


@pytest.mark.anyio
async def test_non_image_payload_never_reaches_storage() -> None:
    repository, storage = InMemoryRepository(), InMemoryStorage()

    with pytest.raises(UnsupportedAvatarTypeError):
        await _service(repository, storage).register_user(
            "Test User", "test-user@prima.it", _upload(b"not an image at all")
        )

    assert storage.objects == {}
    assert repository.users == []


@pytest.fixture()
def anyio_backend() -> str:
    """Run the async tests on asyncio only (trio is not a dependency)."""
    return "asyncio"
