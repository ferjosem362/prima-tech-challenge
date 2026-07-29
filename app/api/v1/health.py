"""Health endpoints.

Split in two on purpose, because Kubernetes/ALB probes mean different things:

* ``/health/live``  -> is the process alive?  Never touches a dependency, so a
  transient DynamoDB outage does not get the container killed and restarted.
* ``/health/ready`` -> can it serve traffic?  Verifies table and bucket, so a
  misconfigured instance is pulled out of the load balancer instead of failing
  user requests.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import SettingsDep, UserServiceDep

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live", summary="Liveness probe")
async def live(settings: SettingsDep) -> dict[str, str]:
    return {
        "status": "ok",
        "service": settings.app_name,
        "version": settings.app_version,
        "environment": settings.environment,
    }


@router.get(
    "/ready",
    summary="Readiness probe",
    responses={503: {"description": "A downstream dependency is unavailable"}},
)
async def ready(service: UserServiceDep) -> dict[str, str]:
    await service.healthcheck()  # raises AppError -> 503 problem+json
    return {"status": "ready"}
