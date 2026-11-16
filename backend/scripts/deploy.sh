#!/usr/bin/env bash
# Deploy a prebuilt backend image on the production VM.
#
# Usage: backend/scripts/deploy.sh <image_tag>
#
# Expects to run on the VM inside the checked-out repo, with backend/.env present
# and `docker login ghcr.io` already done for the current user. Pulls the image,
# recreates the stack, waits for the api healthcheck, and rolls back to the
# previously deployed tag if the new one never becomes healthy.
set -euo pipefail

TAG="${1:?usage: deploy.sh <image_tag>}"
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BACKEND_DIR"

ENV_FILE=.env
if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE not found in $BACKEND_DIR" >&2
  exit 1
fi

PREV_TAG="$(grep -E '^BACKEND_IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2- || true)"

# Persist the tag in .env so a later plain `docker compose up -d` reuses it.
set_tag() {
  if grep -qE '^BACKEND_IMAGE_TAG=' "$ENV_FILE"; then
    sed -i "s|^BACKEND_IMAGE_TAG=.*|BACKEND_IMAGE_TAG=$1|" "$ENV_FILE"
  else
    printf '\nBACKEND_IMAGE_TAG=%s\n' "$1" >> "$ENV_FILE"
  fi
}

wait_healthy() {
  local cid status
  for _ in $(seq 1 30); do
    cid="$(docker compose ps -q api)"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 3
  done
  return 1
}

echo "==> deploying $TAG (previous: ${PREV_TAG:-none})"
set_tag "$TAG"
docker compose pull api
docker compose up -d --no-build --remove-orphans

if wait_healthy; then
  echo "==> api healthy on $TAG"
  docker image prune -f >/dev/null
  exit 0
fi

echo "==> api failed its healthcheck on $TAG; last 100 log lines:" >&2
docker compose logs --no-color --tail=100 api || true

if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ]; then
  echo "==> rolling back to $PREV_TAG" >&2
  set_tag "$PREV_TAG"
  docker compose up -d --no-build api
  if wait_healthy; then
    echo "==> rollback to $PREV_TAG is healthy" >&2
  else
    echo "==> rollback is also unhealthy; manual intervention required" >&2
  fi
fi
exit 1
