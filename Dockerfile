# syntax=docker/dockerfile:1

# ---------- Stage 1: build the dependency layer ---------------------------
# Wheels are compiled once here and only the resulting virtualenv is copied
# into the runtime image, which keeps compilers out of the final artifact.
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copied on its own so the layer is cached until the dependencies change.
COPY requirements.txt .

# pip is deliberately NOT upgraded here. The base image ships a known-good
# version, whereas `pip install --upgrade pip` would pull whatever PyPI serves
# on the day of the build — the exact non-reproducibility that pinning every
# dependency in requirements.txt exists to prevent. (It is also what hadolint
# flags as DL3013.) The long `--requirement` form documents the intent.
RUN pip install --requirement requirements.txt

# ---------- Stage 2: runtime ---------------------------------------------
FROM python:3.12-slim AS runtime

ARG APP_VERSION=1.0.0
ARG VCS_REF=unknown

# OCI labels: `docker inspect` on a running container tells you exactly which
# commit produced it, which is what you want at 3am during an incident.
LABEL org.opencontainers.image.title="prima-tech-challenge" \
      org.opencontainers.image.description="User API backed by DynamoDB and S3" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="MIT"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION="${APP_VERSION}"

# Never run as root: a container escape should not start with uid 0.
RUN groupadd --system app && useradd --system --gid app --home /app app

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app app ./app

USER app
EXPOSE 8000

# The orchestrator's own probe should target /health/ready; this is the
# fallback for plain `docker run`.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health/live').status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
