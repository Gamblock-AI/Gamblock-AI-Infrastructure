#!/bin/bash
# Pull the latest image for this application and restart the container.
# Runs on the VPS (called by CI via SSH, or by ansible). Expects to be run from
# the application's install dir containing docker-compose.yml.
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PROJECT_NAME=$(basename "$PWD")
PASSWORD_FILE="${DOCKER_PASSWORD_FILE:-/opt/docker-stack/docker-password.txt}"
REGISTRY="${DOCKER_REGISTRY:-ghcr.io}"
REGISTRY_USER="${DOCKER_REGISTRY_USER:-gamblock-ai}"
LOG_FILE="/var/log/docker-updates/${COMPOSE_PROJECT_NAME}.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [INFO] $*" | tee -a "$LOG_FILE" 2>/dev/null || true
}

error_exit() {
  log "ERROR: $*"
  exit 1
}

# Record current image IDs (for cleanup after pull).
mapfile -t COMPOSE_IMAGES < <(docker compose -f "$COMPOSE_FILE" config --images)
declare -A OLD_IMAGE_IDS
for IMAGE in "${COMPOSE_IMAGES[@]}"; do
  OLD_IMAGE_IDS["$IMAGE"]=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
done

# Authenticate to the registry.
if [ -f "$PASSWORD_FILE" ]; then
  log "Logging in to ${REGISTRY}"
  cat "$PASSWORD_FILE" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin \
    || error_exit "GHCR login failed"
else
  log "No password file at ${PASSWORD_FILE}; assuming image is public or already authed"
fi

# Pull latest images.
log "Pulling images"
docker compose -f "$COMPOSE_FILE" pull || error_exit "docker compose pull failed"

# Recreate containers with the new image.
log "Recreating containers"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate || error_exit "docker compose up failed"

# Logout for hygiene.
docker logout "$REGISTRY" >/dev/null 2>&1 || true

# Cleanup old images no longer referenced by a running container.
log "Cleaning up old images"
RUNNING_IMAGE_IDS=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' | sort -u)
for IMAGE in "${COMPOSE_IMAGES[@]}"; do
  OLD_ID="${OLD_IMAGE_IDS[$IMAGE]:-}"
  NEW_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
  [ -z "$OLD_ID" ] && continue
  [ "$OLD_ID" = "$NEW_ID" ] && continue
  if echo "$RUNNING_IMAGE_IDS" | grep -qF "$OLD_ID"; then
    log "Skipping $IMAGE old image: still in use"
    continue
  fi
  if docker rmi "$OLD_ID" >/dev/null 2>&1; then
    log "Removed old image for $IMAGE"
  fi
done

log "Update completed for ${COMPOSE_PROJECT_NAME}"
