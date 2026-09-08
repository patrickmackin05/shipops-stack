#!/usr/bin/env bash
# Reproduce the multi-engine backup verification matrix.
#
#   ./test-engines.sh              # all three engines
#   ./test-engines.sh mysql        # just one
#
# Starts throwaway MySQL and MongoDB containers, seeds them, builds a healthy /
# truncated / schema-only backup of each, and checks that both verification
# stages reach the right verdict in all cases. Postgres is tested against the
# running sandbox stack if it is up.
#
# Everything it creates is removed on exit. Expect about two minutes.

set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${HERE}/../scripts"
WORK="$(mktemp -d)"
ONLY="${1:-all}"
PASS=0; FAIL=0

MY_C=shipops-test-mysql-1
MO_C=shipops-test-mongodb-1
MO_EMPTY=shipops-test-mongo-empty

cleanup() {
  docker rm -f "$MY_C" "$MO_C" "$MO_EMPTY" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
good() { PASS=$((PASS+1)); printf '  \033[1;32m OK \033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

# Run a check and assert the exit code is what we expect.
# expect=good -> must exit 0 · expect=bad -> must exit non-zero
assert() {
  local label="$1" expect="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$expect" == good ]]; then
    (( rc == 0 )) && good "$label" || bad "$label (expected success, got exit $rc)"
  else
    (( rc != 0 )) && good "$label" || bad "$label (a bad backup was accepted)"
  fi
}

verify_stage() {  # the nightly pre-upload check inside backup.sh
  local file="$1"; shift
  env "$@" bash -c '
    set -Eeuo pipefail
    . "'"$SCRIPTS"'/lib/common.sh"
    load_engine "$DB_ENGINE" "'"$SCRIPTS"'/lib"
    db_verify "$DB_CONTAINER" "$1" >/dev/null
  ' _ "$file"
}

restore_stage() { # the weekly restore verification
  local file="$1"; shift
  env "$@" ENV_FILE=/dev/null "$SCRIPTS/restore-test.sh" --local "$file"
}

run_engine() {   # engine label, then env assignments
  local label="$1" good_f="$2" trunc_f="$3" schema_f="$4"; shift 4
  say "$label"
  assert "healthy backup passes the nightly check"      good verify_stage  "$good_f"   "$@"
  assert "healthy backup passes the restore test"       good restore_stage "$good_f"   "$@"
  assert "truncated backup caught by nightly check"     bad  verify_stage  "$trunc_f"  "$@"
  assert "truncated backup caught by restore test"      bad  restore_stage "$trunc_f"  "$@"
  assert "schema-only backup caught by nightly check"   bad  verify_stage  "$schema_f" "$@"
  assert "schema-only backup caught by restore test"    bad  restore_stage "$schema_f" "$@"
}

# ── Postgres ────────────────────────────────────────────────────────────────
if [[ "$ONLY" == all || "$ONLY" == postgres ]]; then
  PG_C="${PG_C:-linkjar-postgres-1}"
  if docker inspect "$PG_C" >/dev/null 2>&1; then
    docker exec "$PG_C" pg_dump -U linkjar -d linkjar --format=custom --compress=6 \
      --no-owner --no-privileges > "$WORK/pg.dump"
    head -c 2000 "$WORK/pg.dump" > "$WORK/pg-trunc.dump"
    docker exec "$PG_C" pg_dump -U linkjar -d linkjar --format=custom --schema-only \
      --no-owner --no-privileges > "$WORK/pg-schema.dump"
    run_engine "Postgres" "$WORK/pg.dump" "$WORK/pg-trunc.dump" "$WORK/pg-schema.dump" \
      DB_ENGINE=postgres STACK_NAME=linkjar DB_CONTAINER="$PG_C" \
      POSTGRES_USER=linkjar POSTGRES_DB=linkjar
  else
    say "Postgres"; echo "  skipped - the sandbox stack is not running"
  fi
fi

# ── MySQL ───────────────────────────────────────────────────────────────────
if [[ "$ONLY" == all || "$ONLY" == mysql ]]; then
  say "MySQL (starting a throwaway instance)"
  docker rm -f "$MY_C" >/dev/null 2>&1 || true
  docker run -d --name "$MY_C" -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=shopdb \
    -e MYSQL_USER=shopuser -e MYSQL_PASSWORD=shoppw mysql:8 >/dev/null
  until docker exec -e MYSQL_PWD=shoppw "$MY_C" mysql -ushopuser -N -B -e 'SELECT 1' shopdb >/dev/null 2>&1; do sleep 3; done

  docker exec -e MYSQL_PWD=shoppw -i "$MY_C" mysql -ushopuser shopdb <<'SQL'
CREATE TABLE IF NOT EXISTS products (id INT AUTO_INCREMENT PRIMARY KEY, sku VARCHAR(32) UNIQUE, name VARCHAR(200)) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS orders (id INT AUTO_INCREMENT PRIMARY KEY, product_id INT, qty INT) ENGINE=InnoDB;
INSERT IGNORE INTO products (sku,name) VALUES ('A','Keyboard'),('B','Hub'),('C','Arm'),('D','Mat');
INSERT INTO orders (product_id,qty) SELECT id,1 FROM products;
SQL
  D="-e MYSQL_PWD=shoppw"
  # shellcheck disable=SC2086
  docker exec $D "$MY_C" mysqldump -ushopuser --single-transaction --quick --no-tablespaces shopdb 2>/dev/null | gzip -6 > "$WORK/my.sql.gz"
  head -c 500 "$WORK/my.sql.gz" > "$WORK/my-trunc.sql.gz"
  # shellcheck disable=SC2086
  docker exec $D "$MY_C" mysqldump -ushopuser --no-data --no-tablespaces shopdb 2>/dev/null | gzip -6 > "$WORK/my-schema.sql.gz"

  run_engine "MySQL 8" "$WORK/my.sql.gz" "$WORK/my-trunc.sql.gz" "$WORK/my-schema.sql.gz" \
    DB_ENGINE=mysql STACK_NAME=shipops-test DB_CONTAINER="$MY_C" \
    MYSQL_USER=shopuser MYSQL_PASSWORD=shoppw MYSQL_DATABASE=shopdb
fi

# ── MongoDB ─────────────────────────────────────────────────────────────────
if [[ "$ONLY" == all || "$ONLY" == mongodb ]]; then
  say "MongoDB (starting a throwaway instance)"
  A="-u mongoroot -p mongopw --authenticationDatabase admin"
  for c in "$MO_C" "$MO_EMPTY"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker run -d --name "$c" -e MONGO_INITDB_ROOT_USERNAME=mongoroot \
      -e MONGO_INITDB_ROOT_PASSWORD=mongopw mongo:7 >/dev/null
  done
  for c in "$MO_C" "$MO_EMPTY"; do
    # shellcheck disable=SC2086
    until docker exec "$c" mongosh --quiet $A --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; do sleep 2; done
  done

  # shellcheck disable=SC2086
  docker exec "$MO_C" mongosh --quiet $A appdb --eval '
    db.products.insertMany([{sku:"A"},{sku:"B"},{sku:"C"},{sku:"D"}]);
    const e=[]; for (let i=0;i<40;i++) e.push({type:"view",i:i});
    db.events.insertMany(e); "ok"' >/dev/null
  # A schema-only archive needs a source whose collections exist but are empty.
  # shellcheck disable=SC2086
  docker exec "$MO_EMPTY" mongosh --quiet $A appdb --eval \
    'db.createCollection("products"); db.createCollection("events"); "ok"' >/dev/null

  # shellcheck disable=SC2086
  docker exec "$MO_C"     mongodump --quiet --archive --gzip --db=appdb $A > "$WORK/mo.archive.gz"
  # shellcheck disable=SC2086
  docker exec "$MO_EMPTY" mongodump --quiet --archive --gzip --db=appdb $A > "$WORK/mo-schema.archive.gz"
  head -c 400 "$WORK/mo.archive.gz" > "$WORK/mo-trunc.archive.gz"

  run_engine "MongoDB 7" "$WORK/mo.archive.gz" "$WORK/mo-trunc.archive.gz" "$WORK/mo-schema.archive.gz" \
    DB_ENGINE=mongodb STACK_NAME=shipops-test DB_CONTAINER="$MO_C" \
    MONGO_INITDB_ROOT_USERNAME=mongoroot MONGO_INITDB_ROOT_PASSWORD=mongopw MONGO_DATABASE=appdb
fi

say "Result: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 )) || exit 1
