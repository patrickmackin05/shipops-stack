#!/usr/bin/env bash
# ShipOps blue/green deploy with automatic rollback.
#
# Usage (on the server, or over SSH from CI):
#   /opt/shipops/scripts/deploy.sh ghcr.io/client/app:sha-abc1234
#
# How it works:
#   1. Work out which colour (blue/green) is currently serving traffic.
#   2. Pull the new image and start the IDLE colour on it.
#   3. Wait for that container's Docker healthcheck to report healthy.
#   4. Smoke-test it directly over HTTP.
#   5. Only then stop the old colour and persist the new image tag.
#
# If any step fails, the new container is torn down and the old one is left
# untouched and still serving. A failed deploy is a no-op, not an outage.

set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/shipops}"
COMPOSE_FILE="${COMPOSE_FILE:-$STACK_DIR/docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"
APP_PORT="${APP_PORT:-3000}"
HEALTH_PATH="${HEALTH_PATH:-/healthz}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"   # seconds to wait for healthy
DRAIN_SECONDS="${DRAIN_SECONDS:-10}"      # let Caddy notice the new upstream
SMOKE_IMAGE="${SMOKE_IMAGE:-curlimages/curl:8.10.1}"

NEW_IMAGE="${1:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$NEW_IMAGE" ]] || die "usage: deploy.sh <image:tag>"
[[ -f "$COMPOSE_FILE" ]] || die "compose file not found: $COMPOSE_FILE"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
[[ "$NEW_IMAGE" != *:latest ]] || die "refusing to deploy a :latest tag - rollback needs an immutable tag"

cd "$STACK_DIR"

# shellcheck disable=SC1090
STACK_NAME="$(grep -E '^STACK_NAME=' "$ENV_FILE" | cut -d= -f2- || echo shipops)"
STACK_NAME="${STACK_NAME:-shipops}"

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile green "$@"; }

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

# --- 1. determine colours -------------------------------------------------
BLUE="${STACK_NAME}_app_blue"
GREEN="${STACK_NAME}_app_green"

if container_running "$BLUE"; then
  ACTIVE=blue;  ACTIVE_C="$BLUE";  IDLE=green; IDLE_C="$GREEN"
elif container_running "$GREEN"; then
  ACTIVE=green; ACTIVE_C="$GREEN"; IDLE=blue;  IDLE_C="$BLUE"
else
  warn "no app container currently running - treating this as a cold start on blue"
  ACTIVE="";    ACTIVE_C="";       IDLE=blue;  IDLE_C="$BLUE"
fi

PREVIOUS_IMAGE="$(grep -E '^APP_IMAGE=' "$ENV_FILE" | cut -d= -f2- || true)"

log "stack:    $STACK_NAME"
log "active:   ${ACTIVE:-none} (${PREVIOUS_IMAGE:-none})"
log "deploying $NEW_IMAGE onto $IDLE"

# --- 2. pull --------------------------------------------------------------
# Pull first, but accept an image that is already on the host. That covers two
# real cases: a registry blip where the layer is already cached, and local
# rehearsal against an image built on the box. It is deliberately loud, because
# silently deploying a stale local image would be worse than failing.
log "pulling image"
if ! docker pull "$NEW_IMAGE" >/dev/null 2>&1; then
  if docker image inspect "$NEW_IMAGE" >/dev/null 2>&1; then
    warn "could not pull $NEW_IMAGE - using the copy already on this host"
    warn "verify it is the build you expect: docker image inspect $NEW_IMAGE"
  else
    warn "if this is a private registry, the SERVER needs its own credentials -"
    warn "the CI runner's login does not apply here. Run:"
    warn "  /opt/shipops/scripts/registry-login.sh ghcr.io <github-user>"
    die "failed to pull $NEW_IMAGE and it is not present locally"
  fi
fi

# --- 3. bring up the idle colour -----------------------------------------
# Write the new tag to .env so compose renders the right image, but keep a copy
# so a failure can restore it exactly.
cp "$ENV_FILE" "$ENV_FILE.deploy-backup"
restore_env() { mv -f "$ENV_FILE.deploy-backup" "$ENV_FILE" 2>/dev/null || true; }

if grep -qE '^APP_IMAGE=' "$ENV_FILE"; then
  sed -i.bak "s|^APP_IMAGE=.*|APP_IMAGE=${NEW_IMAGE}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
  echo "APP_IMAGE=${NEW_IMAGE}" >> "$ENV_FILE"
fi

rollback() {
  warn "deploy failed - rolling back"
  compose stop "app_${IDLE}" >/dev/null 2>&1 || true
  compose rm -f "app_${IDLE}" >/dev/null 2>&1 || true
  restore_env
  if [[ -n "$ACTIVE_C" ]] && container_running "$ACTIVE_C"; then
    warn "previous version ($ACTIVE, ${PREVIOUS_IMAGE:-unknown}) is still serving - no downtime occurred"
  else
    warn "NO container is serving. Bring the last good image up manually:"
    warn "  deploy.sh ${PREVIOUS_IMAGE:-<last-known-good-tag>}"
  fi
  exit 1
}
trap rollback ERR

# --no-recreate is critical. Without it this step recreates any service whose
# config has changed - and APP_IMAGE in .env has just changed - which would
# restart the container currently serving traffic and cause the exact outage
# blue/green exists to avoid.
log "ensuring dependencies are up"
compose up -d --no-recreate postgres redis caddy >/dev/null

# Pre-pull the smoke-test image so the pull does not happen mid-cutover.
docker image inspect "$SMOKE_IMAGE" >/dev/null 2>&1 || docker pull -q "$SMOKE_IMAGE" >/dev/null 2>&1 || true

log "starting app_${IDLE}"
compose up -d --no-deps --force-recreate "app_${IDLE}" >/dev/null

# --- 4. wait for the healthcheck -----------------------------------------
log "waiting up to ${HEALTH_TIMEOUT}s for app_${IDLE} to report healthy"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while :; do
  state="$(docker inspect -f '{{.State.Health.Status}}' "$IDLE_C" 2>/dev/null || echo missing)"
  case "$state" in
    healthy) log "app_${IDLE} is healthy"; break ;;
    unhealthy)
      warn "container reported unhealthy. Last 40 log lines:"
      docker logs --tail 40 "$IDLE_C" 2>&1 | sed 's/^/    /' >&2
      false ;;
    missing)
      warn "container has no healthcheck or does not exist"
      docker logs --tail 40 "$IDLE_C" 2>&1 | sed 's/^/    /' >&2
      false ;;
  esac
  if (( $(date +%s) >= deadline )); then
    warn "timed out waiting for health. Last 40 log lines:"
    docker logs --tail 40 "$IDLE_C" 2>&1 | sed 's/^/    /' >&2
    false
  fi
  sleep 3
done

# --- 5. smoke test --------------------------------------------------------
# The Docker healthcheck runs inside the container. This checks the app is
# actually reachable over the Docker network the way Caddy will reach it.
log "smoke-testing http://${IDLE_C}:${APP_PORT}${HEALTH_PATH}"
docker run --rm --network "${STACK_NAME}_internal" "$SMOKE_IMAGE" \
  -fsS --max-time 10 "http://app_${IDLE}:${APP_PORT}${HEALTH_PATH}" >/dev/null \
  || die "smoke test failed"

# --- 6. cut over ----------------------------------------------------------
# Caddy health-checks every 3s; give it a moment to add the new upstream to the
# pool before the old one disappears.
log "waiting ${DRAIN_SECONDS}s for Caddy to pick up the new upstream"
sleep "$DRAIN_SECONDS"

if [[ -n "$ACTIVE_C" ]]; then
  log "stopping previous colour ($ACTIVE)"
  compose stop "app_${ACTIVE}" >/dev/null || warn "could not stop app_${ACTIVE}"
  compose rm -f "app_${ACTIVE}" >/dev/null || true
fi

trap - ERR
rm -f "$ENV_FILE.deploy-backup"

# Record history so rollback has a target and so the runbook is not guesswork.
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IDLE" "$NEW_IMAGE" >> "$STACK_DIR/deploy-history.tsv"

log "deployed $NEW_IMAGE on $IDLE"
log "rollback with: deploy.sh ${PREVIOUS_IMAGE:-<see deploy-history.tsv>}"
