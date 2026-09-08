#!/usr/bin/env bash
# Postgres adapter.
#
# Dumps in custom format (-Fc): already compressed, restorable in parallel, and
# a single table can be pulled out of it. A plain SQL dump piped through gzip is
# slower to restore and all-or-nothing.

db_container_default() { echo "${STACK_NAME:-shipops}-postgres-1"; }
db_dump_ext()          { echo "dump"; }
db_noun()              { echo "table"; }
db_noun_plural()       { echo "tables"; }

db_dump() {
  local c="$1" out="$2"
  docker exec "$c" pg_dump \
    -U "${POSTGRES_USER:?POSTGRES_USER not set}" \
    -d "${POSTGRES_DB:?POSTGRES_DB not set}" \
    --format=custom --compress=6 --no-owner --no-privileges > "$out"
}

# Custom-format archives need seekable input to read their table of contents,
# so the file is copied in rather than piped.
db_verify() {
  local c="$1" f="$2" toc n data
  docker cp "$f" "${c}:/tmp/verify.dump" >/dev/null 2>&1 || return 1
  toc=$(docker exec "$c" pg_restore --list /tmp/verify.dump 2>/dev/null || true)
  docker exec "$c" rm -f /tmp/verify.dump >/dev/null 2>&1 || true

  n=$(grep -c '^[0-9]' <<<"$toc" || true)
  [[ "${n:-0}" -gt 0 ]] || return 1

  # A schema-only dump parses perfectly and lists every table - and restores to
  # an empty database. The archive's table of contents distinguishes the two:
  # real data appears as "TABLE DATA" entries.
  data=$(grep -c 'TABLE DATA' <<<"$toc" || true)
  if [[ "${data:-0}" -eq 0 && -z "${BACKUP_ALLOW_EMPTY:-}" ]]; then
    warn "the dump contains schema but no table data - it would restore an empty database"
    warn "set BACKUP_ALLOW_EMPTY=1 if this database really is empty"
    return 1
  fi
  echo "$n"
}

db_test_image() {
  docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || echo "postgres:16-alpine"
}

db_start_test() {
  local name="$1" image="$2"
  docker run -d --name "$name" \
    -e POSTGRES_USER=verify -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=verify \
    "$image" >/dev/null || return 1
  local i
  for i in $(seq 1 45); do
    docker exec "$name" pg_isready -U verify -d verify >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

db_restore() {
  local name="$1" f="$2"
  docker exec -i "$name" pg_restore -U verify -d verify \
    --no-owner --no-privileges --exit-on-error < "$f"
}

_pgq() { docker exec "$1" psql -U "$2" -d "$3" -tAc "$4" 2>/dev/null || true; }

db_collections() {
  _pgq "$1" verify verify \
    "SELECT table_name FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name" | tr -d '\r'
}

db_count_test() { _pgq "$1" verify verify "SELECT count(*) FROM \"$2\"" | tr -d '[:space:]'; }

db_count_live() {
  _pgq "$1" "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-postgres}" \
    "SELECT count(*) FROM \"$2\"" | tr -d '[:space:]'
}
