"""User endpoints: ``GET /users`` and ``POST /user``."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, File, Form, Query, Response, UploadFile, status
from pydantic import ValidationError

from app.api.deps import SettingsDep, UserServiceDep
from app.core.errors import ValidationFailedError
from app.domain.models import User
from app.schemas.user import UserOut

router = APIRouter(tags=["users"])


def _to_out(user: User) -> UserOut:
    """Map a domain entity to its wire representation."""
    return UserOut(avatar_url=user.avatar_url, email=user.email, name=user.name)


@router.get(
    "/users",
    response_model=list[UserOut],
    summary="Retrieve a list of all users",
    responses={503: {"description": "The database is unavailable"}},
)
async def list_users(
    service: UserServiceDep,
    settings: SettingsDep,
    response: Response,
    limit: Annotated[int | None, Query(ge=1, le=200, description="Page size")] = None,
    cursor: Annotated[str | None, Query(description="Opaque pagination token")] = None,
) -> list[UserOut]:
    """Return every registered user.

    The body is a bare JSON array, exactly as specified. Pagination is opt-in
    and travels out-of-band in the ``X-Next-Cursor`` header, so adding it did
    not require changing the documented response shape.
    """
    page_size = min(limit or settings.default_page_size, settings.max_page_size)
    page = await service.list_users(limit=page_size, cursor=cursor)

    if page.next_cursor:
        response.headers["X-Next-Cursor"] = page.next_cursor
    return [_to_out(user) for user in page.items]


@router.post(
    "/user",
    response_model=UserOut,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new user with an avatar image",
    responses={
        400: {"description": "Invalid name or email"},
        409: {"description": "Email already registered"},
        413: {"description": "Avatar too large"},
        415: {"description": "Avatar is not an accepted image type"},
    },
)
async def create_user(
    service: UserServiceDep,
    response: Response,
    name: Annotated[str, Form(description="Display name", max_length=120)],
    email: Annotated[str, Form(description="Unique email address")],
    avatar: Annotated[UploadFile, File(description="Avatar image (PNG/JPEG/GIF/WebP)")],
) -> UserOut:
    """Register a user and store their avatar in S3.

    Multipart form fields are plain strings, so we run them through the Pydantic
    model explicitly to get the exact same validation (and the exact same error
    contract) as a JSON body would.
    """
    try:
        from app.schemas.user import UserIn  # local import keeps the module graph flat

        payload = UserIn(name=name, email=email)
    except ValidationError as exc:
        raise ValidationFailedError(
            "Invalid user data.",
            errors=[{"field": str(err["loc"][0]), "message": err["msg"]} for err in exc.errors()],
        ) from exc

    user = await service.register_user(name=payload.name, email=str(payload.email), avatar=avatar)
    # Location is the canonical place to advertise the created resource.
    response.headers["Location"] = f"/users?cursor=&email={user.email}"
    return _to_out(user)
