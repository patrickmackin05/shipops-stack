#!/usr/bin/env bash
# Shared helpers for backup.sh and restore-test.sh.
#
# The database-specific work lives in lib/engine-<name>.sh. Each engine defines
# the same set of db_* functions, so the two driver scripts contain exactly one
# code path regardless of whether the client runs Postgres, MySQL or MongoDB.
#
# The interface an engine must implement:
#
#   db_container_default          echo the conventional container name
#   db_dump_ext                   echo the dump file extension
#   db_noun / db_noun_plural      echo "table"/"tables" or "collection"/"collections"
#   db_dump      CONTAINER OUT    write a dump of the live database to OUT
#   db_verify    CONTAINER FILE   echo an object count; non-zero exit if unreadable
#   db_test_image CONTAINER       echo the image to run a throwaway instance from
#   db_start_test NAME IMAGE      start a disposable instance and wait for ready
#   db_restore   NAME FILE        restore FILE into the disposable instance
#   db_collections NAME           list tables/collections, one per line
#   db_count_test NAME COLL       echo the row/document count in the disposable copy
#   db_count_live CONTAINER COLL  echo the same count from the live database
#
# One rule every engine follows: always run client tools from INSIDE the
# database container, never from the host. Host client tools drift out of step
# with the server version, and an older client reading a newer dump reports a
# perfectly healthy backup as corrupt. See docs/verification.md.

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] warn: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

alert() {
  [[ -n "${ALERT_WEBHOOK_URL:-}" ]] || return 0
  local msg="$1" payload
  if command -v jq >/dev/null 2>&1; then
    payload=$(printf '{"content":%s,"text":%s}' "$(jq -Rs . <<<"$msg")" "$(jq -Rs . <<<"$msg")")
  else
    # Minimal escaping so a missing jq cannot silence alerting entirely.
    local esc=${msg//\\/\\\\}; esc=${esc//\"/\\\"}; esc=${esc//$'\n'/ }
    payload=$(printf '{"content":"%s","text":"%s"}' "$esc" "$esc")
  fi
  curl -fsS -m 10 -X POST -H 'content-type: application/json' -d "$payload" \
    "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || warn "alert webhook failed"
}

# sha256sum is GNU coreutils; macOS ships `shasum`. Support both so the scripts
# can be rehearsed locally before they are trusted on a server.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

# Pick the first of a list of binaries that exists inside a container. Client
# tools get renamed between versions - MariaDB ships `mariadb` alongside a
# deprecated `mysql`, Mongo replaced `mongo` with `mongosh` - and hardcoding one
# name means the script breaks on an image the client happened to pick.
container_bin() {
  local c="$1"; shift
  local b
  for b in "$@"; do
    if docker exec "$c" sh -c "command -v $b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  done
  return 1
}

# Work out which engine this stack runs. An explicit DB_ENGINE always wins;
# otherwise look for a container matching each engine's naming convention.
detect_engine() {
  if [[ -n "${DB_ENGINE:-}" ]]; then echo "${DB_ENGINE}"; return 0; fi
  local stack="${STACK_NAME:-shipops}" e
  for e in postgres mysql mongodb; do
    if container_running "${stack}-${e}-1"; then echo "$e"; return 0; fi
  done
  # Legacy override from the Postgres-only version of these scripts.
  if [[ -n "${PG_CONTAINER:-}" ]] && container_running "$PG_CONTAINER"; then
    echo postgres; return 0
  fi
  return 1
}

load_engine() {
  local engine="$1" dir="$2"
  case "$engine" in
    postgres|postgresql|pg) engine=postgres ;;
    mysql|mariadb)          engine=mysql ;;
    mongo|mongodb)          engine=mongodb ;;
    *) echo "unsupported DB_ENGINE: $engine (expected postgres, mysql or mongodb)" >&2; return 1 ;;
  esac
  # shellcheck source=/dev/null
  . "${dir}/engine-${engine}.sh"
  ENGINE="$engine"
}
