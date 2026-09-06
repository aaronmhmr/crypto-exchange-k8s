# syntax=docker/dockerfile:1

# Pinned by digest (python:3.11-slim-trixie as of 2026-09-06). 3.11 is the
# ceiling for Django 4.1 (see APP_CHANGES.md for why Django isn't
# upgraded); trixie because Debian bookworm's standard support window ended
# 2026-07-11.
ARG PYTHON_IMAGE=python@sha256:9534e5a8e315485d4061ed659af0fd78a284c015f9b73661b41d6bab25604534

# ---- builder --------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

# libc6-dev is only a Recommends of gcc, not a Depends -- with
# --no-install-recommends it's skipped, and gcc then has no libc headers
# (stdlib.h etc.) to compile psycopg2's C extension against. Must be listed
# explicitly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        libc6-dev \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
# psycopg2 (compiled from source, not psycopg2-binary) needs pg_config from
# libpq-dev above -- trade-off: slower image build, but a correctly-linked
# libpq rather than the bundled one psycopg2-binary vendors.
RUN pip install --no-cache-dir -r requirements.txt

COPY Exchange/ Exchange/
WORKDIR /app/Exchange

# collectstatic needs *a* SECRET_KEY to import settings.py, but never a real
# one -- this value never leaves the build stage and is not the runtime key.
RUN DJANGO_SECRET_KEY=build-time-only-not-a-real-secret \
    DATABASE_NAME=x DATABASE_USER=x DATABASE_PASSWORD=x DATABASE_HOST=x DATABASE_PORT=5432 \
    python manage.py collectstatic --noinput

# ---- runtime ----------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

# procps provides pgrep, used by the worker Deployment's exec probes
# (the django-q qcluster worker has no HTTP endpoint to probe).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        tzdata \
        procps \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DJANGO_SETTINGS_MODULE=Exchange.settings

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app/Exchange /app/Exchange

WORKDIR /app/Exchange

# media/ upload subdirectories must be writable under a read-only root
# filesystem (see k8s manifests); the baked-in default images
# (media/bitcoin_icon.png, media/default_avatar.jpg) stay part of the image.
RUN mkdir -p media/token_logo media/profile_pics \
    && chown -R app:app /app/Exchange/media /app/Exchange/staticfiles

USER 10001:10001
EXPOSE 8000

# Shell form + exec so gunicorn becomes PID 1 (proper SIGTERM handling for
# graceful shutdown) while still allowing GUNICORN_WORKERS to come from the
# ConfigMap. Binds 0.0.0.0, not 127.0.0.1 -- binding loopback here is one of
# the concrete causes of the 502 troubleshooting scenario in the README.
CMD exec gunicorn Exchange.wsgi:application \
    --bind 0.0.0.0:8000 \
    --workers "${GUNICORN_WORKERS:-3}" \
    --threads 2 \
    --timeout 60 \
    --graceful-timeout 30 \
    --access-logfile - \
    --error-logfile -
