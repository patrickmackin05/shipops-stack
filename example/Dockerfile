# syntax=docker/dockerfile:1.7
# ShipOps standard Node.js production image.
#
# Multi-stage: dependencies are installed in a builder layer so that build
# toolchains and dev dependencies never reach the runtime image. Expect roughly
# ~300MB on bookworm-slim, of which ~260MB is the Debian + Node base itself,
# against 1.1GB+ for a naive `FROM node` + `npm install`. Switch the base to
# -alpine for roughly half that, but only once you have verified every native
# dependency builds against musl - `bcrypt` and `sharp` are the usual casualties.
#
# Per-client edits (should be the only things you touch):
#   - NODE_VERSION, if the client is not on 22
#   - the `npm run build` line: delete it for a plain Express/Fastify service,
#     keep it for Next.js / Vite / anything with a build step
#   - COPY --from=build lines: they must match what the build step emits
#   - the CMD

ARG NODE_VERSION=22.18.0

# --- deps -----------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
# `npm ci` requires a lockfile and installs it exactly. If the client has no
# lockfile, generate one and commit it before deploying - without it every
# build pulls different transitive versions and "works on my machine" returns.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --include=dev

# --- build ----------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Delete this line for apps with no build step.
RUN if npm run | grep -qE '^  build'; then npm run build; fi

# --- production dependencies ---------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS prod-deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# --- runtime --------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS runtime

# Stamp the build so the running container can say which image it is. CI passes
# --build-arg APP_VERSION=$GITHUB_SHA. Without this, "is the deploy live yet?"
# can only be answered by squinting at container start times.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# tini reaps zombies and forwards signals, so SIGTERM actually reaches Node and
# graceful shutdown works. Without it, PID 1 is Node and Docker's stop can hang
# for the full 10s timeout on every single deploy.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The node image already ships an unprivileged `node` user (uid 1000). Use it.
# A container running as root that is compromised is a root-on-host problem
# waiting for one kernel or runtime bug.
# Order matters. The build stage's /app contains dev dependencies, so its
# node_modules is deleted before the production-only tree is copied in. Doing
# it the other way round leaves every dev dependency in the shipped image -
# bigger, slower to pull, and a much larger CVE surface.
COPY --from=build --chown=node:node /app ./
RUN rm -rf /app/node_modules /app/.git /app/.github
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules

USER node
EXPOSE 3000

# Container-level health. Compose and deploy.sh both read this: a container
# that never reports healthy is never promoted, which is what makes the
# rollback in deploy.sh automatic rather than manual.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3000/healthz || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "src/server.js"]
