#!/usr/bin/env bash
# ShipOps database backup -> object storage.
#
# Supports Postgres, MySQL/MariaDB and MongoDB. The engine is taken from
# DB_ENGINE, or detected from the running containers.
#
# Usage:
#   /opt/shipops/scripts/backup.sh            # normal run, reads /opt/shipops/.env
#   BACKUP_DRY_RUN=1 ./backup.sh              # dump and verify, keep the file, skip upload
#   DB_ENGINE=mysql ./backup.sh               # force an engine
#
# Design notes:
#   * Every dump is verified BEFORE upload. Uploading a truncated dump and only
#     finding out during a real incident is the exact failure this service exists
#     to prevent.
#   * Any failure sends an alert. A backup job that fails silently is worse than
#     no backup job, because you stop worrying about it.
#   * The retention prune only runs after a successful, size-verified upload, so
#     a broken backup can never delete good history.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${STACK_DIR:-/opt/shipops}"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

STACK_NAME="${STACK_NAME:-shipops}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
STAGING="${BACKUP_STAGING:-/tmp/shipops-backup}"

die() { log "ERROR: $*"; alert "Backup FAILED on ${STACK_NAME}: $*"; exit 1; }

ENGINE="$(detect_engine)" || die "could not determine the database engine - set DB_ENGINE to postgres, mysql or mongodb"
load_engine "$ENGINE" "${SCRIPT_DIR}/lib" || die "could not load engine adapter for '$ENGINE'"

DB_CONTAINER="${DB_CONTAINER:-${PG_CONTAINER:-$(db_container_default)}}"
container_running "$DB_CONTAINER" || die "database container '$DB_CONTAINER' is not running"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_NAME="${STACK_NAME}-${TIMESTAMP}.$(db_dump_ext)"
DUMP_PATH="${STAGING}/${DUMP_NAME}"

cleanup() { rm -f "$DUMP_PATH" "${DUMP_PATH}.sha256"; }
trap cleanup EXIT

[[ -n "${BACKUP_BUCKET:-}" || -n "${BACKUP_DRY_RUN:-}" ]] || die "BACKUP_BUCKET not set"
mkdir -p "$STAGING"

log "engine: ${ENGINE} · container: ${DB_CONTAINER}"

# --- 1. dump --------------------------------------------------------------
log "dumping to ${DUMP_NAME}"
db_dump "$DB_CONTAINER" "$DUMP_PATH" || die "dump failed - see the container logs for $DB_CONTAINER"

SIZE_BYTES=$(wc -c < "$DUMP_PATH" | tr -d ' ')
log "dump written (${SIZE_BYTES} bytes)"

# This floor only catches an empty or zero-byte dump. It is deliberately low:
# a compressed archive of a small database is legitimately under a kilobyte
# (a seeded Mongo archive measured 802 bytes), and a size threshold that fires
# on healthy backups trains you to ignore the alert. The real check is the
# engine's own verification below, which parses the archive.
(( SIZE_BYTES >= ${BACKUP_MIN_BYTES:-256} )) \
  || die "dump is only ${SIZE_BYTES} bytes - the database is empty or the dump failed silently"

# --- 2. verify ------------------------------------------------------------
# Each engine verifies in the way that actually proves something for its own
# format, using client tools from inside the database container so a version
# mismatch can never report a healthy backup as corrupt.
log "verifying archive integrity"
OBJECTS=$(db_verify "$DB_CONTAINER" "$DUMP_PATH") \
  || die "verification failed - the dump is unreadable or truncated"
log "archive OK (${OBJECTS} $(db_noun_plural))"

sha256 "$DUMP_PATH" > "${DUMP_PATH}.sha256"
log "sha256: $(cat "${DUMP_PATH}.sha256")"

if [[ -n "${BACKUP_DRY_RUN:-}" ]]; then
  # Keep the artefacts. A dry run doubles as "take me a manual backup right
  # now, before I run this risky migration", which is a thing you will want.
  trap - EXIT
  log "BACKUP_DRY_RUN set - skipping upload and prune"
  log "dump kept at: ${DUMP_PATH}"
  exit 0
fi

# --- 3. upload ------------------------------------------------------------
# Cloudflare R2 and AWS S3 both speak the S3 API; AWS_ENDPOINT_URL selects R2.
S3_ARGS=()
[[ -n "${AWS_ENDPOINT_URL:-}" ]] && S3_ARGS+=(--endpoint-url "$AWS_ENDPOINT_URL")

DEST="${BACKUP_BUCKET%/}/${STACK_NAME}/${TIMESTAMP:0:4}/${DUMP_NAME}"
log "uploading to ${DEST}"
aws "${S3_ARGS[@]}" s3 cp "$DUMP_PATH" "$DEST" --only-show-errors || die "upload failed"
aws "${S3_ARGS[@]}" s3 cp "${DUMP_PATH}.sha256" "${DEST}.sha256" --only-show-errors \
  || die "checksum upload failed"

# `aws s3 cp` has exited 0 on partial writes before now, so confirm the object
# is really there and really the right size.
REMOTE_SIZE=$(aws "${S3_ARGS[@]}" s3api head-object \
  --bucket "$(sed -E 's#^s3://([^/]+).*#\1#' <<<"$BACKUP_BUCKET")" \
  --key "$(sed -E 's#^s3://[^/]+/?##' <<<"${DEST}")" \
  --query ContentLength --output text 2>/dev/null || echo 0)

[[ "$REMOTE_SIZE" == "$SIZE_BYTES" ]] \
  || die "uploaded size ${REMOTE_SIZE} != local size ${SIZE_BYTES}"
log "upload verified (${REMOTE_SIZE} bytes)"

# --- 4. prune -------------------------------------------------------------
# Retention can be handled two ways, and the choice is a security decision.
#
#   BACKUP_PRUNE=off  - the bucket's own lifecycle rule expires old objects.
#                       The server then needs NO delete permission at all, so a
#                       compromised server cannot destroy the backups. This is
#                       the right choice for client work: the machine most
#                       likely to be attacked should not hold the power to
#                       erase its own recovery path.
#
#   BACKUP_PRUNE=on   - this script deletes old objects itself (the default,
#                       and what Cloudflare R2 setups generally use).
if [[ "${BACKUP_PRUNE:-on}" != "on" ]]; then
  log "BACKUP_PRUNE=off - leaving retention to the bucket's lifecycle rule"
  log "backup complete: ${DEST}"
  exit 0
fi

log "pruning backups older than ${RETENTION_DAYS} days"
CUTOFF=$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
      || date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%dT%H:%M:%S)

PRUNED=0
while read -r line; do
  [[ -z "$line" ]] && continue
  obj_date=$(awk '{print $1"T"$2}' <<<"$line")
  obj_key=$(awk '{print $4}' <<<"$line")
  [[ -z "$obj_key" ]] && continue
  if [[ "$obj_date" < "$CUTOFF" ]]; then
    # Deliberately tolerant: a failed delete must not abort the run, because
    # the backup itself has already uploaded successfully by this point. A
    # permissions error here should be a warning, not a lost backup.
    if aws "${S3_ARGS[@]}" s3 rm "${BACKUP_BUCKET%/}/${obj_key}" --only-show-errors; then
      PRUNED=$((PRUNED+1))
    else
      warn "could not delete ${obj_key} - set BACKUP_PRUNE=off if the bucket has a lifecycle rule"
    fi
  fi
done < <(aws "${S3_ARGS[@]}" s3 ls "${BACKUP_BUCKET%/}/${STACK_NAME}/" --recursive 2>/dev/null || true)
log "pruned ${PRUNED} old object(s)"

log "backup complete: ${DEST}"
