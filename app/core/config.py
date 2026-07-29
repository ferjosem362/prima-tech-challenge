"""Application settings.

All configuration is read from the environment (12-factor style) so the very
same artifact can run on a laptop, on LocalStack, or on ECS/Lambda without a
single code change.  Nothing here is ever hard-coded, and no credentials are
handled by the application itself: boto3 resolves them from the standard
provider chain (env vars, shared config, IRSA / instance role...).
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Typed, validated view of the process environment."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        frozen=True,  # settings are immutable once loaded
    )

    # ---- Application -----------------------------------------------------
    app_name: str = "prima-tech-challenge"
    app_version: str = "1.0.0"
    environment: str = Field(default="local", description="local|dev|prod")
    log_level: str = "INFO"
    debug_errors: bool = Field(
        default=False,
        description="When true, unexpected exceptions leak their message in the "
        "HTTP response. Must stay false outside local development.",
    )

    # ---- AWS -------------------------------------------------------------
    aws_region: str = "us-east-1"
    aws_endpoint_url: str | None = Field(
        default=None,
        description="Override for LocalStack/MinIO. None => real AWS endpoints.",
    )

    # ---- Persistence -----------------------------------------------------
    dynamodb_table: str = "users"
    # `email` is the partition key: it is the natural business identifier of a
    # user and gives us uniqueness for free through a conditional write.
    dynamodb_partition_key: str = "email"

    # ---- Object storage --------------------------------------------------
    s3_bucket: str = "prima-tech-challenge"
    s3_avatar_prefix: str = "avatars"
    s3_public_base_url: str | None = Field(
        default=None,
        description="Base URL used to build avatar_url. Defaults to the virtual "
        "hosted-style S3 endpoint. Set it to a CloudFront domain in production.",
    )
    s3_server_side_encryption: str | None = "AES256"

    # ---- Upload guard rails ---------------------------------------------
    max_avatar_bytes: int = 2 * 1024 * 1024  # 2 MiB
    allowed_avatar_types: frozenset[str] = frozenset(
        {"image/png", "image/jpeg", "image/gif", "image/webp"}
    )

    # ---- Pagination ------------------------------------------------------
    default_page_size: int = 50
    max_page_size: int = 200

    @field_validator("log_level")
    @classmethod
    def _upper(cls, value: str) -> str:
        return value.upper()

    @field_validator("aws_endpoint_url", "s3_public_base_url", mode="before")
    @classmethod
    def _empty_to_none(cls, value: object) -> object:
        """Treat an empty variable as an absent one."""
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @property
    def public_base_url(self) -> str:
        """Base URL for publicly readable objects, without trailing slash."""
        if self.s3_public_base_url:
            return self.s3_public_base_url.rstrip("/")
        # Virtual hosted-style URL, e.g.
        # https://prima-tech-challenge.s3.us-east-1.amazonaws.com
        return f"https://{self.s3_bucket}.s3.{self.aws_region}.amazonaws.com"

    def object_url(self, key: str) -> str:
        """Absolute URL of an S3 object key."""
        return f"{self.public_base_url}/{key.lstrip('/')}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process-wide settings singleton.

    Cached so that reading the environment (and the .env file) happens once;
    tests can call ``get_settings.cache_clear()`` to force a reload.
    """
    return Settings()
