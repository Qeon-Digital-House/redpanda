# syntax=docker/dockerfile:1
#
# Builds the Redpanda Console image: a single static Go binary that serves
# both the REST/Connect API and the embedded React frontend on port 8080.
#
# Build:  docker build -t console:local .
# Run:    docker run -p 8080:8080 -e KAFKA_BROKERS=host.docker.internal:9092 console:local
#
# See BUILD.md for details.

ARG BUN_VERSION=1.4.0
ARG GO_VERSION=1.26
ARG ALPINE_VERSION=3.21

# Stage 1: build the React frontend. The output in frontend/build/ gets
# embedded into the Go binary in stage 2.
FROM oven/bun:${BUN_VERSION} AS frontend

WORKDIR /src/frontend

COPY frontend/package.json frontend/bun.lock frontend/bunfig.toml frontend/.npmrc ./
# --ignore-scripts: the only install script that matters at build time is
# isolated-vm's node-gyp build (native binary, only needed at runtime in
# server-side code paths); skipping it also avoids the root package's
# `prepare` script (lefthook), which requires git and a .git directory.
RUN bun install --frozen-lockfile --ignore-scripts

COPY frontend/ ./
ARG REACT_APP_CONSOLE_GIT_SHA=unknown
ARG REACT_APP_CONSOLE_GIT_REF=unknown
ARG REACT_APP_BUILD_TIMESTAMP=0
RUN REACT_APP_CONSOLE_GIT_SHA="${REACT_APP_CONSOLE_GIT_SHA}" \
    REACT_APP_CONSOLE_GIT_REF="${REACT_APP_CONSOLE_GIT_REF}" \
    REACT_APP_BUILD_TIMESTAMP="${REACT_APP_BUILD_TIMESTAMP}" \
    bun run build

# Stage 2: build the Go backend. The compiled frontend assets must be placed
# into backend/pkg/embed/frontend/ before the build so that
# `//go:embed all:frontend` (backend/pkg/embed/frontend.go) picks them up.
FROM golang:${GO_VERSION}-alpine AS backend

WORKDIR /src

COPY backend/go.mod backend/go.sum ./backend/
RUN --mount=type=cache,target=/go/pkg/mod \
    cd backend && go mod download

COPY backend/ ./backend/
RUN mkdir -p ./backend/pkg/embed/frontend
COPY --from=frontend /src/frontend/build/ ./backend/pkg/embed/frontend/

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd backend && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/console ./cmd/api

# Stage 3: runtime image
FROM alpine:${ALPINE_VERSION}

RUN apk --no-cache add ca-certificates && \
    addgroup -S console && adduser -S console -G console

COPY --from=backend /out/console /console-api

USER console
ENV SERVER_LISTENPORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:${SERVER_LISTENPORT}/admin/health" || exit 1

ENTRYPOINT ["/console-api"]
