"""Bridging blocking I/O into the async event loop.

boto3/botocore are synchronous.  Calling them straight from an ``async def``
handler would block the single event-loop thread and serialise every request.
Running them in AnyIO's worker-thread pool keeps the loop free while avoiding an
extra dependency such as aioboto3 (whose API surface we do not need here).
"""

from __future__ import annotations

from collections.abc import Callable
from functools import partial
from typing import ParamSpec, TypeVar

from anyio import to_thread

P = ParamSpec("P")
R = TypeVar("R")


async def run_blocking(func: Callable[P, R], *args: P.args, **kwargs: P.kwargs) -> R:
    """Execute ``func`` in a worker thread and await its result."""
    return await to_thread.run_sync(partial(func, *args, **kwargs))
