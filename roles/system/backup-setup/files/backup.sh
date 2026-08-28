#!/bin/bash
# Scheduled Gamblock-AI backup. Configuration lives in backup.env (rendered by
# Ansible). Dumps every PostgreSQL database on the shared postgres container
# and archives the dynamic file volumes (media/exports/artifacts) attached to
# each backend container, then prunes backups older than the retention window.
set -euo pipefail

BACKUP_ENV="${BACKUP_ENV:-/opt/docker-stack/backups/backup.env}"
if [ -f "$BACKUP_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$BACKUP_ENV"
  set +a
fi

BACKUP_ROOT="${BACKUP_ROOT:-/opt/docker-stack/backups}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres-db}"
POSTGRES_BACKUPS_HOST_DIR="${POSTGRES_BACKUPS_HOST_DIR:-/opt/docker-stack/postgres/backups}"
DB_USER="${DB_USER:-gamblock}"
DB_NAMES="${DB_NAMES:-gamblock gamblock_staging}"
BACKEND_CONTAINERS="${BACKEND_CONTAINERS:-gamblock-ai-backend gamblock-ai-backend-staging}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

TS="$(date +%Y%m%dT%H%M%S)"
DB_DIR="$BACKUP_ROOT/db"
FILES_DIR="$BACKUP_ROOT/files"
mkdir -p "$DB_DIR" "$FILES_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error_exit() { log "ERROR: $*"; exit 1; }

# 1. PostgreSQL dumps (custom format, restorable with pg_restore). The dump is
# written inside the postgres container at /backups (host:
# $POSTGRES_BACKUPS_HOST_DIR) and then moved into the backup root.
for DB in $DB_NAMES; do
  if ! docker exec "$POSTGRES_CONTAINER" pg_dump \
      --username="$DB_USER" --dbname="$DB" --format=custom \
      --file="/backups/scheduled-${DB}-${TS}.dump"; then
    error_exit "pg_dump failed for $DB"
  fi
  mv "$POSTGRES_BACKUPS_HOST_DIR/scheduled-${DB}-${TS}.dump" "$DB_DIR/"
  log "backed up database $DB"
done

# 2. Dynamic file volumes (media/exports/artifacts) for each backend container.
for CONTAINER in $BACKEND_CONTAINERS; do
  VOLUMES=$(docker inspect "$CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' 2>/dev/null || true)
  for VOL in $VOLUMES; do
    VOL_DATA="/var/lib/docker/volumes/${VOL}/_data"
    [ -d "$VOL_DATA" ] || continue
    tar -czf "$FILES_DIR/${VOL}-${TS}.tar.gz" -C "$VOL_DATA" . \
      || error_exit "tar failed for volume $VOL"
    log "backed up volume $VOL"
  done
done

# 3. Retention: prune anything older than RETENTION_DAYS.
find "$DB_DIR" "$FILES_DIR" -type f -mtime "+$RETENTION_DAYS" -delete || true
log "scheduled backup completed ($TS)"
