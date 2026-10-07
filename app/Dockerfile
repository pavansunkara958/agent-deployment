# Multi-stage. The runtime image carries no build tools, no package manager
# cache, and no shell utilities beyond what the app needs — every one of those
# is something an attacker who reaches the container can use.

FROM python:3.12-slim AS build

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target /deps -r requirements.txt

# -----------------------------------------------------------------------------
FROM python:3.12-slim

# Non-root, fixed uid. The uid is pinned because the task definition references
# it, and because a uid that shifts between builds breaks volume permissions.
RUN groupadd --gid 10001 agent \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin agent

COPY --from=build /deps /usr/local/lib/python3.12/site-packages
COPY --chown=10001:10001 src/ /app/src/

WORKDIR /app
USER 10001:10001

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app

# The root filesystem is mounted read-only by the task definition; /tmp is a
# tmpfs. Nothing the container writes survives a restart, which is intended.

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -m src.healthcheck || exit 1

ENTRYPOINT ["python", "-m", "src.main"]
