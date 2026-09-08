#!/usr/bin/env bash
# ShipOps backup restore verification.
#
# Most systems "have backups". Very few have ever restored one. An untested
# backup is a hypothesis, not a safety net - and the moment you find out it was
# wrong is always the worst possible moment.
#
# Supports Postgres, MySQL/MariaDB and MongoDB.
#
# What it does:
#   1. Fetch the most recent backup from object storage (or a local file).
#   2. Verify its sha256 against the checksum stored alongside it.
#   3. Restore it into a disposable database container that touches nothing.
#   4. Assert the restored copy actually contains data - tables/collections
#      exist, and row counts are within tolerance of the live database.
#   5. Tear everything down and report.
#
# Usage:
#   ./restore-test.sh                       # newest backup from BACKUP_BUCKET
#   ./restore-test.sh --local dump.sql.gz   # a specific local file
#   ./restore-test.sh --tables users,orders # only compare these
#
# Exit 0 = the backup is provably restorable. Anything else = act today.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${STACK_DIR:-/opt/shipops}"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

STACK_NAME="${STACK_NAME:-shipops}"
TEST_CONTAINER="shipops-restoretest-$$"
WORK_DIR="$(mktemp -d)"
LOCAL_DUMP=""
EXPECT_TABLES="${EXPECT_TABLES:-}"
# Live counts move on while the dump sits in a bucket. Allow the restored copy
# to be a little behind - but not empty.
DRIFT_TOLERANCE="${DRIFT_TOLERANCE:-0.20}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
die() { log "ERROR: $*"; alert "Restore test FAILED on ${STACK_NAME}: $*"; exit 1; }

cleanup() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)  LOCAL_DUMP="$2"; shift 2 ;;
    --tables) EXPECT_TABLES="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ENGINE="$(detect_engine)" || die "could not determine the database engine - set DB_ENGINE"
load_engine "$ENGINE" "${SCRIPT_DIR}/lib" || die "could not load engine adapter for '$ENGINE'"

DB_CONTAINER="${DB_CONTAINER:-${PG_CONTAINER:-$(db_container_default)}}"
NOUN="$(db_noun)"; NOUNS="$(db_noun_plural)"

log "restore verification starting · engine: ${ENGINE} · stack: ${STACK_NAME}"

# --- 1. obtain a dump -----------------------------------------------------
DUMP="$WORK_DIR/restore.$(db_dump_ext)"

if [[ -n "$LOCAL_DUMP" ]]; then
  [[ -f "$LOCAL_DUMP" ]] || die "no such file: $LOCAL_DUMP"
  cp "$LOCAL_DUMP" "$DUMP"
  log "using local dump: $LOCAL_DUMP"
  [[ -f "${LOCAL_DUMP}.sha256" ]] && cp "${LOCAL_DUMP}.sha256" "${DUMP}.sha256"
else
  : "${BACKUP_BUCKET:?BACKUP_BUCKET not set and no --local given}"
  S3_ARGS=()
  [[ -n "${AWS_ENDPOINT_URL:-}" ]] && S3_ARGS+=(--endpoint-url "$AWS_ENDPOINT_URL")

  log "finding newest backup in ${BACKUP_BUCKET}/${STACK_NAME}/"
  LATEST_LINE=$(aws "${S3_ARGS[@]}" s3 ls "${BACKUP_BUCKET%/}/${STACK_NAME}/" --recursive \
    | grep -E "\.$(db_dump_ext)\$" | sort -k1,2 | tail -1 || true)
  LATEST_KEY=$(awk '{print $4}' <<<"$LATEST_LINE")
  [[ -n "$LATEST_KEY" ]] || die "no backups found in the bucket - backups are not running"

  BUCKET_ROOT="$(sed -E 's#^(s3://[^/]+).*#\1#' <<<"$BACKUP_BUCKET")"
  log "newest backup: ${LATEST_KEY}"

  # A restorable backup from three weeks ago is still a failure.
  BACKUP_EPOCH=$(date -u -d "$(awk '{print $1" "$2}' <<<"$LATEST_LINE")" +%s 2>/dev/null || echo "")
  if [[ -n "$BACKUP_EPOCH" ]]; then
    AGE_H=$(( ( $(date -u +%s) - BACKUP_EPOCH ) / 3600 ))
    if (( AGE_H > 30 )); then
      bad "newest backup is ${AGE_H}h old (expected under 30h) - the backup job is not running"
    else
      ok "backup freshness: ${AGE_H}h old"
    fi
  fi

  aws "${S3_ARGS[@]}" s3 cp "${BUCKET_ROOT}/${LATEST_KEY}" "$DUMP" --only-show-errors || die "download failed"
  aws "${S3_ARGS[@]}" s3 cp "${BUCKET_ROOT}/${LATEST_KEY}.sha256" "${DUMP}.sha256" --only-show-errors 2>/dev/null || true
fi

# --- 2. checksum ----------------------------------------------------------
if [[ -f "${DUMP}.sha256" ]]; then
  EXPECTED="$(tr -d '[:space:]' < "${DUMP}.sha256")"
  ACTUAL="$(sha256 "$DUMP")"
  if [[ "$EXPECTED" == "$ACTUAL" ]]; then
    ok "checksum matches (${ACTUAL:0:16}...)"
  else
    bad "checksum mismatch - the stored backup is corrupt or was truncated in transit"
  fi
else
  log "warn: no checksum file alongside the backup; skipping integrity check"
fi

# --- 3. restore into a disposable container ------------------------------
# The throwaway instance runs the SAME image as the live database, so the
# restore is performed by a version-matched client. Hardcoding a version here
# would silently test the wrong thing the day a client is on an older major.
TEST_IMAGE="${TEST_IMAGE:-$(db_test_image "$DB_CONTAINER")}"
log "starting throwaway ${ENGINE} (${TEST_IMAGE})"
db_start_test "$TEST_CONTAINER" "$TEST_IMAGE" || die "the disposable ${ENGINE} never became ready"

log "restoring dump"
RESTORE_LOG="$WORK_DIR/restore.log"
if db_restore "$TEST_CONTAINER" "$DUMP" > "$RESTORE_LOG" 2>&1; then
  ok "restore completed without errors"
else
  bad "restore reported errors:"
  sed 's/^/       /' "$RESTORE_LOG" | tail -20
fi

# --- 4. assert the data is really there ----------------------------------
COLLECTIONS="$(db_collections "$TEST_CONTAINER" || true)"
COLL_COUNT=$(grep -c . <<<"$COLLECTIONS" || true)
if [[ "${COLL_COUNT:-0}" -gt 0 ]]; then
  ok "restored copy contains ${COLL_COUNT} ${NOUNS}"
else
  bad "restored database has no ${NOUNS} - the dump is empty"
fi

# Comparing against live catches the nastiest failure of all: a backup that
# restores perfectly but contains only the schema.
if container_running "$DB_CONTAINER"; then
  log "comparing counts against the live database"
  if [[ -n "$EXPECT_TABLES" ]]; then
    TARGETS="${EXPECT_TABLES//,/ }"
  else
    TARGETS="$COLLECTIONS"
  fi

  for t in $TARGETS; do
    [[ -z "$t" ]] && continue
    restored=$(db_count_test "$TEST_CONTAINER" "$t" || true)
    live=$(db_count_live "$DB_CONTAINER" "$t" || true)

    if [[ -z "$live" || ! "$live" =~ ^[0-9]+$ ]]; then
      log "  (skipped ${t} - not present in the live database)"
      continue
    fi
    if [[ -z "$restored" || ! "$restored" =~ ^[0-9]+$ ]]; then
      bad "${t}: exists live (${live} rows) but could not be read from the restored copy"
      continue
    fi

    floor=$(awk -v l="$live" -v d="$DRIFT_TOLERANCE" 'BEGIN{printf "%d", l*(1-d)}')
    if (( restored >= floor )); then
      ok "${t}: ${restored} restored (live ${live})"
    else
      bad "${t}: only ${restored} restored but live has ${live}"
    fi
  done
else
  log "live database container not found; skipping the count comparison"
fi

# --- 5. report ------------------------------------------------------------
echo
log "restore verification: ${PASS} passed, ${FAIL} failed"

if (( FAIL > 0 )); then
  alert "Restore test FAILED on ${STACK_NAME} (${ENGINE}): ${FAIL} check(s) failed. The backup may not be usable."
  exit 1
fi

log "backup verified restorable"
alert "Restore test passed on ${STACK_NAME} (${ENGINE}): ${PASS} checks OK, backup is provably restorable."
