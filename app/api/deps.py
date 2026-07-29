"""FastAPI dependency wiring.

This module is the only place where concrete adapters are bound to ports.
Tests override :func:`get_user_service` (or the client factories) to inject
fakes without touching a single route.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from app.core.config import Settings, get_settings
from app.infrastructure.aws import get_dynamodb_client, get_s3_client
from app.infrastructure.dynamodb_user_repository import DynamoDBUserRepository
from app.infrastructure.s3_avatar_storage import S3AvatarStorage
from app.services.user_service import UserService

SettingsDep = Annotated[Settings, Depends(get_settings)]


def get_user_service(settings: SettingsDep) -> UserService:
    """Assemble the use-case object graph for the current request.

    The adapters are cheap wrappers around cached boto3 clients, so building
    them per request costs nothing measurable and keeps the code stateless.
    """
    repository = DynamoDBUserRepository(get_dynamodb_client(), settings)
    storage = S3AvatarStorage(get_s3_client(), settings)
    return UserService(repository=repository, storage=storage, settings=settings)


UserServiceDep = Annotated[UserService, Depends(get_user_service)]
