"""Structured (JSON) logging with request correlation.

Emitting one JSON object per line is what makes the logs directly usable by
CloudWatch Logs Insights / Loki / ELK without brittle regex parsing.  The
current request id lives in a ContextVar so any module can log without having
to thread the id through every function signature.
"""

from __future__ import annotations

import contextvars
import datetime as dt
import json
import logging
import sys
from typing import Any

# Correlation id of the request currently being served ("-" outside a request).
request_id_ctx: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

# Attributes already present in every LogRecord; anything else the caller added
# through `logger.info(..., extra={...})` is considered structured payload.
_RESERVED = frozenset(logging.LogRecord("", 0, "", 0, "", None, None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    """Render a LogRecord as a single-line JSON document."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": dt.datetime.fromtimestamp(record.created, tz=dt.UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_ctx.get(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        # Merge user-supplied `extra=` fields.
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value

        return json.dumps(payload, default=str, ensure_ascii=False)


def configure_logging(level: str = "INFO") -> None:
    """Install the JSON formatter on the root logger (idempotent)."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers.clear()  # drop uvicorn/gunicorn defaults so we own the format
    root.addHandler(handler)
    root.setLevel(level)

    # Uvicorn installs its own handlers; make them propagate to ours instead.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logging.getLogger(name).handlers.clear()
        logging.getLogger(name).propagate = True

    # botocore is extremely chatty at DEBUG and would leak signed headers.
    logging.getLogger("botocore").setLevel(max(logging.INFO, root.level))
