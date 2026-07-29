"""Core domain entities.

Deliberately free of FastAPI, Pydantic and boto3 imports: the domain must not
know how it is transported or persisted.  Frozen dataclasses give us value
semantics and cheap equality in tests.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class User:
    """A registered user.

    Attributes:
        name: Display name.
        email: Business identifier; also the DynamoDB partition key.
        avatar_url: Absolute, publicly reachable URL of the avatar image.
    """

    name: str
    email: str
    avatar_url: str


@dataclass(frozen=True, slots=True)
class Page:
    """One page of users plus the opaque cursor to fetch the next one."""

    items: list[User]
    next_cursor: str | None = None
