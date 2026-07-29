"""Pydantic DTOs: the public shape of the API, decoupled from the domain."""

from __future__ import annotations

from typing import Annotated

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

# Reusable constrained types keep the validation rules in one place.
NameStr = Annotated[str, Field(min_length=1, max_length=120)]


class UserIn(BaseModel):
    """Validated multipart form fields of ``POST /user``."""

    model_config = ConfigDict(str_strip_whitespace=True)

    name: NameStr
    email: EmailStr

    @field_validator("email")
    @classmethod
    def _normalise_email(cls, value: str) -> str:
        # The email is the partition key, so "A@B.com" and "a@b.com" must not
        # create two different users. The domain part is case-insensitive by
        # RFC 5321; lowercasing the whole address is the pragmatic convention.
        return value.lower()


class UserOut(BaseModel):
    """Representation returned by the API.

    Field order mirrors the expected payload of the challenge
    (``avatar_url``, ``email``, ``name``).
    """

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "avatar_url": "https://prima-tech-challenge.s3.us-east-1.amazonaws.com/avatars/9f1c.png",
                "email": "test-user@prima.it",
                "name": "Test User",
            }
        }
    )

    avatar_url: str
    email: EmailStr
    name: str
