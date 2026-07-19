#!/bin/bash
# Pull the latest image for this application and restart it. Root is logged in
# to GHCR once by Ansible, so no plaintext registry password file is needed.
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PROJECT_NAME=$(basename "$PWD")
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

# Pull latest images.
log "Pulling images"
docker compose -f "$COMPOSE_FILE" pull || error_exit "docker compose pull failed"

# Recreate containers with the new image.
log "Recreating containers"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate || error_exit "docker compose up failed"

# Do not delete the previous image until every service is running and healthy.
log "Waiting for services to become ready"
mapfile -t COMPOSE_CONTAINERS < <(docker compose -f "$COMPOSE_FILE" ps -q)
[ "${#COMPOSE_CONTAINERS[@]}" -gt 0 ] || error_exit "compose started no containers"

for attempt in $(seq 1 60); do
  ready=true
  for container in "${COMPOSE_CONTAINERS[@]}"; do
    state=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
    if [ "$state" != "running" ] || { [ "$health" != "none" ] && [ "$health" != "healthy" ]; }; then
      ready=false
      break
    fi
  done
  [ "$ready" = true ] && break
  [ "$attempt" -eq 60 ] && error_exit "services did not become ready within 180 seconds"
  sleep 3
done

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
