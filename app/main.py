"""Application entry point: ``uvicorn app.main:app``."""

from __future__ import annotations

import logging
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response

from app.api.v1.router import api_router
from app.core.config import Settings, get_settings
from app.core.errors import install_exception_handlers
from app.core.logging import configure_logging, request_id_ctx

logger = logging.getLogger(__name__)

# Header used to propagate a correlation id across services.
REQUEST_ID_HEADER = "X-Request-ID"


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup/shutdown hooks."""
    settings: Settings = get_settings()
    logger.info(
        "application_start",
        extra={
            "environment": settings.environment,
            "table": settings.dynamodb_table,
            "bucket": settings.s3_bucket,
        },
    )
    # Build the boto3 clients eagerly so the first real request does not pay the
    # ~200 ms service-model parsing penalty (cold-start smoothing).
    from app.infrastructure.aws import get_dynamodb_client, get_s3_client

    get_dynamodb_client()
    get_s3_client()

    yield

    logger.info("application_stop")


def create_app() -> FastAPI:
    """Application factory (keeps tests free to build isolated instances)."""
    settings = get_settings()
    configure_logging(settings.log_level)

    app = FastAPI(
        title="Prima Tech Challenge - User API",
        version=settings.app_version,
        summary="Register users with an avatar and list them back.",
        description=(
            "A small, production-shaped REST API: users are persisted in "
            "DynamoDB and their avatars in S3.\n\n"
            "Errors follow RFC 9457 (`application/problem+json`)."
        ),
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )

    @app.middleware("http")
    async def correlation_and_access_log(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        """Attach a request id, time the request and emit one access log line."""
        request_id = request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex
        token = request_id_ctx.set(request_id)
        started = time.perf_counter()
        try:
            response = await call_next(request)
        finally:
            elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
            request_id_ctx.reset(token)

        response.headers[REQUEST_ID_HEADER] = request_id
        logger.info(
            "http_request",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status": response.status_code,
                "duration_ms": elapsed_ms,
            },
        )
        return response

    install_exception_handlers(app)
    app.include_router(api_router)

    @app.get("/", include_in_schema=False)
    async def root() -> dict[str, str]:
        """Tiny landing payload pointing at the interactive docs."""
        return {"service": settings.app_name, "docs": "/docs"}

    return app


# ASGI application object picked up by uvicorn/gunicorn.
app = create_app()
