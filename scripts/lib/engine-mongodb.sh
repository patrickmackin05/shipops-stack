#!/usr/bin/env bash
# MongoDB adapter.
#
# mongodump --archive --gzip produces a single compressed archive file, which
# keeps the driver's staging, checksum and upload logic identical across engines.
#
# The archive is NOT a plain gzip stream (each collection is compressed inside
# an envelope), so `gzip -t` proves nothing here. Integrity is checked by having
# mongorestore parse the whole archive with --dryRun, which reads and validates
# every section without writing anything.

db_container_default() { echo "${STACK_NAME:-shipops}-mongodb-1"; }
db_dump_ext()          { echo "archive.gz"; }
db_noun()              { echo "collection"; }
db_noun_plural()       { echo "collections"; }

_mongo_db()   { echo "${MONGO_DATABASE:?MONGO_DATABASE not set}"; }
_mongo_user() { echo "${MONGO_INITDB_ROOT_USERNAME:-${MONGO_USER:-}}"; }
_mongo_pass() { echo "${MONGO_INITDB_ROOT_PASSWORD:-${MONGO_PASSWORD:-}}"; }

# Auth flags, omitted entirely when the deployment runs without authentication.
_mongo_auth() {
  local u p
  u="$(_mongo_user)"; p="$(_mongo_pass)"
  [[ -n "$u" && -n "$p" ]] && printf -- '-u %s -p %s --authenticationDatabase admin' "$u" "$p"
}

# The official images have bundled the database tools since 4.4, but a slim or
# custom image may not. Say so clearly rather than failing with "not found".
_mongo_require_tools() {
  container_bin "$1" mongodump >/dev/null 2>&1 && return 0
  warn "mongodump is not installed in $1."
  warn "Use an image that bundles the MongoDB database tools, or install"
  warn "mongodb-database-tools in your Mongo image."
  return 1
}

db_dump() {
  local c="$1" out="$2"
  _mongo_require_tools "$c" || return 1
  # shellcheck disable=SC2046  # deliberate word-splitting of the auth flags
  docker exec "$c" mongodump --quiet --archive --gzip \
    --db="$(_mongo_db)" $(_mongo_auth) > "$out"
}

# Verifying a Mongo archive is the fiddliest part of this whole stack, and
# the obvious approach is wrong in a way that matters.
#
# `mongorestore --dryRun` reads only the archive PRELUDE - the header listing
# which collections are inside. Measured: it exits 0 on an archive truncated to
# 400 bytes. Trusting it would mean cheerfully uploading corrupt backups and
# reporting them healthy, which is the exact failure this service exists to
# prevent.
#
# So verification happens in two stages:
#   1. Prelude -> how many collections the archive CLAIMS to contain.
#   2. Deep    -> actually restore into a scratch namespace, which forces every
#                 byte to be read, then compare what arrived against the claim
#                 and drop the scratch database.
#
# Measured behaviour of the deep stage:
#   good archive       exit 0, 2 of 2 collections
#   truncated archive  exit 1, 1 of 2 collections
#   empty file         exit 1, 0 of 2 collections
#
# The deep stage writes a temporary copy into the live server, so it is skipped
# for archives above MONGO_DEEP_VERIFY_MAX_BYTES (default 500MB) - on a large
# database that copy is not a reasonable thing to do nightly. When it is
# skipped you get a loud warning, and the weekly restore-test.sh remains the
# real proof. Set MONGO_VERIFY_MODE=prelude to skip it always.
db_verify() {
  local c="$1" f="$2"
  local out names declared size scratch restored rc

  out=$(docker exec -i "$c" mongorestore --archive --gzip --dryRun -v < "$f" 2>&1 || true)
  names=$(grep -o 'archive prelude `[^`]*`' <<<"$out" | sed 's/.*`\(.*\)`/\1/' || true)
  declared=$(grep -c . <<<"$names" || true)

  if [[ "${declared:-0}" -eq 0 ]]; then
    warn "the archive header lists no collections - it is empty or unreadable"
    return 1
  fi

  size=$(wc -c < "$f" | tr -d ' ')
  local max="${MONGO_DEEP_VERIFY_MAX_BYTES:-524288000}"

  if [[ "${MONGO_VERIFY_MODE:-deep}" != "deep" ]]; then
    warn "MONGO_VERIFY_MODE is not 'deep': header parsed only, contents NOT verified"
    warn "a truncated archive would pass this check - rely on the weekly restore test"
    echo "$declared"; return 0
  fi
  if (( size > max )); then
    warn "archive is ${size} bytes, above MONGO_DEEP_VERIFY_MAX_BYTES (${max})"
    warn "skipping the deep check: header parsed only, contents NOT verified"
    warn "a truncated archive would pass this check - rely on the weekly restore test"
    echo "$declared"; return 0
  fi

  scratch="shipops_verify_$$"
  local sh; sh=$(container_bin "$c" mongosh mongo) || { warn "no mongo shell in $c"; return 1; }
  _drop_scratch() {
    # shellcheck disable=SC2046
    docker exec "$c" "$sh" --quiet $(_mongo_auth) "$scratch" \
      --eval 'db.dropDatabase()' >/dev/null 2>&1 || true
  }

  # shellcheck disable=SC2046
  docker exec -i "$c" mongorestore --quiet --archive --gzip $(_mongo_auth) \
    --nsFrom="$(_mongo_db).*" --nsTo="${scratch}.*" --drop < "$f" >/dev/null 2>&1
  rc=$?

  # shellcheck disable=SC2046
  restored=$(docker exec "$c" "$sh" --quiet $(_mongo_auth) "$scratch" \
    --eval 'db.getCollectionNames().filter(n => !n.startsWith("system.")).length' 2>/dev/null | tr -d '[:space:]')
  # Documents, not just collections: an archive of empty collections restores
  # cleanly and contains nothing.
  local docs
  # shellcheck disable=SC2046
  docs=$(docker exec "$c" "$sh" --quiet $(_mongo_auth) "$scratch" \
    --eval 'db.getCollectionNames().filter(n => !n.startsWith("system.")).reduce((a,n) => a + db.getCollection(n).countDocuments({}), 0)' 2>/dev/null | tr -d '[:space:]')
  _drop_scratch

  if (( rc != 0 )); then
    warn "restoring the archive failed (exit ${rc}) - it is truncated or corrupt"
    return 1
  fi
  if [[ "${restored:-0}" -lt "$declared" ]]; then
    warn "archive claims ${declared} collections but only ${restored} restored - it is incomplete"
    return 1
  fi
  if [[ "${docs:-0}" -eq 0 && -z "${BACKUP_ALLOW_EMPTY:-}" ]]; then
    warn "the archive restored ${restored} collections but zero documents - it would restore an empty database"
    warn "set BACKUP_ALLOW_EMPTY=1 if this database really is empty"
    return 1
  fi

  echo "$declared"
}

db_test_image() {
  docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || echo "mongo:7"
}

db_start_test() {
  local name="$1" image="$2" sh i
  docker run -d --name "$name" \
    -e MONGO_INITDB_ROOT_USERNAME=verify -e MONGO_INITDB_ROOT_PASSWORD=verify \
    "$image" >/dev/null || return 1
  for i in $(seq 1 60); do
    sh=$(container_bin "$name" mongosh mongo 2>/dev/null) || { sleep 1; continue; }
    if docker exec "$name" "$sh" --quiet -u verify -p verify --authenticationDatabase admin \
         --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

db_restore() {
  local name="$1" f="$2"
  docker exec -i "$name" mongorestore --quiet --archive --gzip \
    -u verify -p verify --authenticationDatabase admin < "$f"
}

_mongo_eval_test() {
  local name="$1" js="$2" sh
  sh=$(container_bin "$name" mongosh mongo) || return 0
  docker exec "$name" "$sh" --quiet -u verify -p verify --authenticationDatabase admin \
    "$(_mongo_db)" --eval "$js" 2>/dev/null || true
}

db_collections() {
  _mongo_eval_test "$1" 'db.getCollectionNames().filter(n => !n.startsWith("system.")).join("\n")' | tr -d '\r'
}

db_count_test() { _mongo_eval_test "$1" "db.getCollection(\"$2\").countDocuments({})" | tr -d '[:space:]'; }

db_count_live() {
  local c="$1" coll="$2" sh
  sh=$(container_bin "$c" mongosh mongo) || return 0
  # shellcheck disable=SC2046
  docker exec "$c" "$sh" --quiet $(_mongo_auth) "$(_mongo_db)" \
    --eval "db.getCollection(\"$coll\").countDocuments({})" 2>/dev/null | tr -d '[:space:]' || true
}
