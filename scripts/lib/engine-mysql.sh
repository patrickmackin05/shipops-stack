#!/usr/bin/env bash
# MySQL / MariaDB adapter.
#
# mysqldump emits plain SQL, so the dump is gzipped on the way out. Unlike
# Postgres custom format there is no table of contents to parse, so integrity is
# checked three ways: the gzip stream must be valid, the dump must end with
# mysqldump's own completion trailer (its absence is the signature of a
# truncated or killed dump), and it must contain at least one CREATE TABLE.

db_container_default() { echo "${STACK_NAME:-shipops}-mysql-1"; }
db_dump_ext()          { echo "sql.gz"; }
db_noun()              { echo "table"; }
db_noun_plural()       { echo "tables"; }

# MariaDB renamed the client tools and keeps the mysql-prefixed names only as
# deprecated symlinks, so resolve whichever this image actually ships.
_my_dumpbin() { container_bin "$1" mysqldump mariadb-dump; }
_my_cli()     { container_bin "$1" mysql mariadb; }

_my_user() { echo "${MYSQL_USER:-${MYSQL_ROOT_USER:-root}}"; }
_my_pass() { echo "${MYSQL_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"; }
_my_db()   { echo "${MYSQL_DATABASE:?MYSQL_DATABASE not set}"; }

db_dump() {
  local c="$1" out="$2" dump extra=""
  dump=$(_my_dumpbin "$c") || { warn "no mysqldump in $c"; return 1; }

  # --set-gtid-purged is MySQL-only; MariaDB's dumper rejects it outright.
  if docker exec "$c" "$dump" --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
    extra="--set-gtid-purged=OFF"
  fi

  # --single-transaction  consistent snapshot without locking the app out
  # --quick               stream rows instead of buffering the table in RAM
  # --no-tablespaces      avoids needing the PROCESS privilege, which an
  #                       application user correctly does not have
  # MYSQL_PWD keeps the password out of the container's process list.
  docker exec -e MYSQL_PWD="$(_my_pass)" "$c" "$dump" \
    -u "$(_my_user)" \
    --single-transaction --quick --no-tablespaces --routines --triggers \
    $extra ${MYSQLDUMP_EXTRA_ARGS:-} \
    "$(_my_db)" 2>/dev/null | gzip -6 > "$out"
}

db_verify() {
  # Called as (container, file). Only the file is needed: gzip and grep are
  # generic tools, so there is no client/server version skew to guard against.
  local f="$2" n trailer
  gzip -t "$f" 2>/dev/null || return 1

  # Read into a variable rather than piping into grep -q: an early-exiting grep
  # would SIGPIPE gzip and trip pipefail in the caller.
  trailer=$(gzip -dc "$f" 2>/dev/null | tail -5 || true)
  [[ "$trailer" == *"Dump completed"* ]] || return 1

  n=$(gzip -dc "$f" 2>/dev/null | grep -c '^CREATE TABLE' || true)
  [[ "${n:-0}" -gt 0 ]] || return 1

  # `mysqldump --no-data` produces a dump that is valid, complete and useless.
  # Rows arrive as INSERT statements, so their absence is the tell.
  local inserts
  inserts=$(gzip -dc "$f" 2>/dev/null | grep -c '^INSERT INTO' || true)
  if [[ "${inserts:-0}" -eq 0 && -z "${BACKUP_ALLOW_EMPTY:-}" ]]; then
    warn "the dump contains schema but no INSERT statements - it would restore an empty database"
    warn "set BACKUP_ALLOW_EMPTY=1 if this database really is empty"
    return 1
  fi
  echo "$n"
}

db_test_image() {
  docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || echo "mysql:8"
}

db_start_test() {
  local name="$1" image="$2" cli i
  docker run -d --name "$name" \
    -e MYSQL_ROOT_PASSWORD=verify -e MYSQL_DATABASE=verify \
    "$image" >/dev/null || return 1

  # MySQL initialises, then restarts its own server during first boot. Polling
  # only for "server answers" can catch that first, pre-restart server and race
  # the restore against a shutdown, so wait for a real query to succeed twice.
  local ok=0
  for i in $(seq 1 90); do
    cli=$(_my_cli "$name" 2>/dev/null) || { sleep 1; continue; }
    if docker exec -e MYSQL_PWD=verify "$name" "$cli" -uroot -N -B -e 'SELECT 1' verify >/dev/null 2>&1; then
      ok=$((ok+1)); [[ $ok -ge 2 ]] && return 0
    else
      ok=0
    fi
    sleep 1
  done
  return 1
}

db_restore() {
  local name="$1" f="$2" cli
  cli=$(_my_cli "$name") || return 1
  gzip -dc "$f" | docker exec -i -e MYSQL_PWD=verify "$name" "$cli" -uroot verify
}

_myq_test() {
  local name="$1" sql="$2" cli
  cli=$(_my_cli "$name") || return 0
  docker exec -e MYSQL_PWD=verify "$name" "$cli" -uroot -N -B -e "$sql" verify 2>/dev/null || true
}

db_collections() {
  _myq_test "$1" "SELECT table_name FROM information_schema.tables
    WHERE table_schema=DATABASE() AND table_type='BASE TABLE' ORDER BY table_name" | tr -d '\r'
}

db_count_test() { _myq_test "$1" "SELECT COUNT(*) FROM \`$2\`" | tr -d '[:space:]'; }

db_count_live() {
  local c="$1" tbl="$2" cli
  cli=$(_my_cli "$c") || return 0
  docker exec -e MYSQL_PWD="$(_my_pass)" "$c" "$cli" -u "$(_my_user)" -N -B \
    -e "SELECT COUNT(*) FROM \`$tbl\`" "$(_my_db)" 2>/dev/null | tr -d '[:space:]' || true
}
