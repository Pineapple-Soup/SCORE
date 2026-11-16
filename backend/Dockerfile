FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Pin the uv major so builds are reproducible; bump deliberately.
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /uvx /bin/

WORKDIR /app

# Install dependencies first so this layer is cached until the lockfile changes.
# --no-dev keeps pyrefly and other dev tooling out of the production image.
COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Copy application source and install the project itself.
# models/ (YOLO training data) is intentionally not copied: preprocessing is disabled.
COPY app ./app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# Create tmp and out directories
RUN mkdir -p tmp out

ENV PORT=8000
EXPOSE 8000

CMD ["uv", "run", "--no-sync", "fastapi", "run", "--host", "0.0.0.0", "--port", "8000"]
