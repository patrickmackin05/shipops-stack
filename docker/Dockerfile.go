# syntax=docker/dockerfile:1.7
# ShipOps standard Go production image.
#
# Go compiles to a static binary, so the runtime stage can be distroless: no
# shell, no package manager, no libc to CVE-scan. Final images are ~15-25MB.
#
# Per-client edits: GO_VERSION, the ./cmd/... build path, the port.

ARG GO_VERSION=1.23

# --- build ----------------------------------------------------------------
FROM golang:${GO_VERSION}-bookworm AS build
WORKDIR /src

# Download modules first so dependency changes, not source changes, bust the cache.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
# CGO off gives a genuinely static binary; -trimpath and -ldflags strip build
# paths and debug symbols so the binary is smaller and reproducible.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w" \
      -o /out/app ./cmd/server

# --- runtime --------------------------------------------------------------
# distroless/static ships CA certificates, tzdata and a nonroot user - nothing else.
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080

# No shell and no curl in distroless, so the health endpoint must be probed by
# the binary itself: implement `app -healthcheck` to hit /healthz and exit 0/1.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app", "-healthcheck"]

ENTRYPOINT ["/app"]
