"""Domain error hierarchy and HTTP problem responses.

Errors are raised as *domain* exceptions by the service/adapters layers and
translated into HTTP only at the edge (see ``install_exception_handlers``).
That keeps the business code free of any web framework import and makes it
trivially unit-testable.

The wire format follows RFC 9457 (Problem Details for HTTP APIs), so every
error looks the same to a client:

    {"type": "about:blank", "title": "...", "status": 409,
     "detail": "...", "code": "user_already_exists", "request_id": "..."}
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.config import get_settings
from app.core.logging import request_id_ctx

logger = logging.getLogger(__name__)

PROBLEM_MEDIA_TYPE = "application/problem+json"


class AppError(Exception):
    """Base class for every expected (i.e. handled) application error."""

    status_code: int = 500
    code: str = "internal_error"
    title: str = "Internal Server Error"

    def __init__(self, detail: str | None = None, **extra: Any) -> None:
        self.detail = detail or self.title
        self.extra = extra
        super().__init__(self.detail)


# --- 4xx: the caller can fix it ------------------------------------------
class ValidationFailedError(AppError):
    status_code, code, title = 400, "validation_failed", "Invalid request payload"


class UserAlreadyExistsError(AppError):
    status_code, code, title = 409, "user_already_exists", "User already exists"


class AvatarTooLargeError(AppError):
    status_code, code, title = 413, "avatar_too_large", "Avatar exceeds size limit"


class UnsupportedAvatarTypeError(AppError):
    status_code = 415
    code = "unsupported_avatar_type"
    title = "Unsupported avatar media type"


class InvalidCursorError(AppError):
    status_code, code, title = 400, "invalid_cursor", "Malformed pagination cursor"


# --- 5xx: the caller cannot fix it ---------------------------------------
class RepositoryError(AppError):
    status_code, code, title = 503, "repository_unavailable", "Database error"


class StorageError(AppError):
    status_code, code, title = 503, "storage_unavailable", "Object storage error"


def _problem(status: int, code: str, title: str, detail: str, **extra: Any) -> JSONResponse:
    """Build an RFC 9457 problem+json response."""
    body: dict[str, Any] = {
        "type": "about:blank",
        "title": title,
        "status": status,
        "detail": detail,
        "code": code,
        "request_id": request_id_ctx.get(),
    }
    body.update(extra)
    return JSONResponse(status_code=status, content=body, media_type=PROBLEM_MEDIA_TYPE)


def install_exception_handlers(app: FastAPI) -> None:
    """Register the translation layer domain-exception -> HTTP response."""

    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError) -> JSONResponse:
        # 5xx are unexpected enough to deserve a stack trace; 4xx are not.
        log = logger.error if exc.status_code >= 500 else logger.warning
        log("request_failed", extra={"error_code": exc.code, "status": exc.status_code})
        return _problem(exc.status_code, exc.code, exc.title, exc.detail, **exc.extra)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        # Normalise FastAPI's 422 into our 400 contract, keeping field details.
        errors = [
            {"field": ".".join(str(p) for p in err["loc"][1:]) or "body", "message": err["msg"]}
            for err in exc.errors()
        ]
        return _problem(
            400,
            "validation_failed",
            "Invalid request payload",
            "One or more fields are invalid.",
            errors=errors,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return _problem(
            exc.status_code,
            "http_error",
            str(exc.detail),
            str(exc.detail),
        )

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        # Last line of defence: never let a traceback reach the client.
        logger.exception("unhandled_exception")
        detail = str(exc) if get_settings().debug_errors else "Unexpected server error."
        return _problem(500, "internal_error", "Internal Server Error", detail)
