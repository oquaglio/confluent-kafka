# Python API. Dependencies are installed at build time with uv, so a change to
# pyproject.toml / uv.lock needs `action: rebuild`. app.py is synced and the container
# restarted (`action: sync+restart`), which is much faster than a rebuild.
FROM python:3.13.7-slim
COPY --from=ghcr.io/astral-sh/uv:0.8.15 /uv /usr/local/bin/uv

ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1

# Non-root user. Synced files are written as this user, so it must own the target dir.
RUN useradd --create-home --uid 10001 app && mkdir /app && chown app:app /app
WORKDIR /app

# Not --locked: the demo edits pyproject.toml without re-locking, so uv re-resolves here.
COPY pyproject.toml uv.lock ./
RUN uv sync --no-dev --no-install-project

COPY --chown=app:app app.py ./
USER app
EXPOSE 8000
CMD ["python", "app.py"]
