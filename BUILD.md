# Building Console from Source

This guide explains how to build a runnable Docker image of Redpanda Console from this
repository, and how to run it against a Kafka/Redpanda cluster.

The result is a single container image containing one static Go binary that serves both the
REST/Connect API and the embedded React frontend on port **8080**. The frontend is compiled
with Bun and embedded into the Go binary at build time — the runtime stage contains only the
binary, CA certificates, and a non-root `console` user.

## Prerequisites

- Docker 23+ (or another BuildKit-capable builder). The Dockerfile uses BuildKit cache
  mounts, so builds run best with BuildKit enabled (the default on recent Docker versions).
- Network access to pull base images and dependencies (Bun, Go, and npm/Go modules).
- No other tooling is required on the host — Bun, Go, and all dependencies are installed
  inside the build stages.

## Build the image

From the repository root:

```bash
docker build -t console:local .
```

The build is a three-stage pipeline (see [Image structure](#image-structure) below). On a
warm cache, the Go and npm dependency layers are cached and only your code changes are
rebuilt.

### Build arguments

These arguments are passed to the React build and surface in the UI. They are informational;
safe defaults are baked in.

| Argument | Default | Purpose |
|---|---|---|
| `REACT_APP_CONSOLE_GIT_SHA` | `unknown` | Commit the frontend was built from, e.g. `$(git rev-parse --short HEAD)` |
| `REACT_APP_CONSOLE_GIT_REF` | `unknown` | Branch or tag name, e.g. `main` or `v2.3.8` |
| `REACT_APP_BUILD_TIMESTAMP` | `0` | Build time as epoch milliseconds |

Example with version metadata:

```bash
docker build \
  --build-arg REACT_APP_CONSOLE_GIT_SHA="$(git rev-parse --short HEAD)" \
  --build-arg REACT_APP_CONSOLE_GIT_REF="$(git rev-parse --abbrev-ref HEAD)" \
  --build-arg REACT_APP_BUILD_TIMESTAMP="$(date +%s%3N)" \
  -t console:local .
```

### Multi-arch builds

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t console:local .
```

### CI builds

Every commit to `main` is built and published automatically by
[.github/workflows/docker-image.yml](.github/workflows/docker-image.yml): the image is
built, smoke-tested (liveness probe + frontend served), then pushed to GHCR with the tags
`main` and `sha-<short-sha>` (e.g. `ghcr.io/redpanda-data/console:sha-1a2b3c4`).

## Run the image

The container needs at least one Kafka/Redpanda broker to connect to. From the host:

```bash
docker run -p 8080:8080 \
  -e KAFKA_BROKERS=host.docker.internal:9092 \
  console:local
```

Then open http://localhost:8080.

- `host.docker.internal` resolves to the host machine. On Linux, add
  `--add-host=host.docker.internal:host-gateway` if the name is not resolved automatically.
- If the container and the broker share a Docker network, use the broker's DNS name instead
  (e.g. `redpanda:9092`, see [docs/local/docker-compose.yaml](docs/local/docker-compose.yaml)).
- Kafka brokers advertise their own addresses to clients after the initial connection, so
  make sure your advertised listeners are reachable from inside the container — using
  `localhost:9092` only works with `--network=host`.

### Docker Compose

Build and deploy are separate steps: the image is built with `docker build` (above), then
[compose.yaml](compose.yaml) deploys it together with a single-node Kafka broker (KRaft,
no ZooKeeper):

```bash
docker build -t console:local .
docker compose up
```

Then open http://localhost:8080. What runs:

- `broker` — `apache/kafka:3.7.0`. Port `9092` is the host-facing listener (advertised as
  `localhost:9092`), so tools on the host connect via `localhost:9092`. Inside the compose
  network the broker is reachable as `broker:19092` — Console is preconfigured with that
  address for exactly this reason; pointing it at `broker:9092` would break after the first
  metadata response (the advertised-listener trap described above).
- `console` — the `console:local` image built in the first step, published on port 8080.
  `docker compose up` fails fast with "image not found" if you skip it; re-run the build
  whenever your code changed, then `docker compose up -d --force-recreate console` to
  replace the running container.

To reset the environment, `docker compose down` (Kafka state lives in the container's
`/tmp/kraft-combined-logs`, so it is discarded with the container).

### Configuration

Console is configured via a YAML config file, environment variables, or flags (see
[pkg/config](backend/pkg/config)). Precedence is flags, then config file, then environment
variables, with `SetDefaults` values underneath — the exact order is load-bearing, see
`LoadConfig` in [backend/pkg/config/config.go](backend/pkg/config/config.go).

- **Config file**: mount one and point at it via the `CONFIG_FILEPATH` environment variable
  or the `--config.filepath` flag. A fully documented reference config lives at
  [docs/config/console.yaml](docs/config/console.yaml).
- **Environment variables**: map 1:1 to config keys with `_` replacing `.` (case
  insensitive), e.g.:
  - `KAFKA_BROKERS=broker1:9092,broker2:9092`
  - `SERVER_LISTENPORT=8080`
  - `KAFKA_SASL_ENABLED=true`, `KAFKA_SASL_USERNAME=...`, `KAFKA_SASL_PASSWORD=...`
- **Flags**: `--help` on the binary lists all registered flags.

### Health checks

The image ships with a `HEALTHCHECK` polling `GET /admin/health`. The container also exposes
`GET /admin/startup` (startup probe) and `GET /admin/metrics` (Prometheus metrics), all on
the same port. These routes are intended for orchestrators and should be protected at the
ingress if you expose Console publicly.

## Image structure

| Stage | Base image | What it does |
|---|---|---|
| `frontend` | `oven/bun` | `bun install --frozen-lockfile --ignore-scripts` + `bun run build` → `frontend/build/` |
| `backend` | `golang:1.26-alpine` | `go mod download`, copies the frontend output into `backend/pkg/embed/frontend/`, builds a static `console` binary |
| runtime | `alpine` | CA certificates, non-root user, the binary, nothing else |

Why the copy step in stage 2: the Go binary embeds the frontend with
`//go:embed all:frontend` in [backend/pkg/embed/frontend.go](backend/pkg/embed/frontend.go).
The `.gitignore` in `backend/pkg/embed/frontend/` keeps compiled assets out of git, so the
assets must be placed there before `go build` runs — in Docker, the `frontend` stage output
is copied in; outside Docker you do it manually (see next section).

The image runs as the non-root `console` user. Volumes for config files must be readable by
that user — get the numeric UID with
`docker run --rm --entrypoint sh console:local -c 'id -u'`.

## Building without Docker (local build)

Useful for debugging; this is the same flow the e2e suite automates
([frontend/tests/shared/global-setup.mjs](frontend/tests/shared/global-setup.mjs)):

```bash
# 1. Frontend (requires Bun 1.4+, see frontend/package.json)
cd frontend && bun install --frozen-lockfile && bun run build

# 2. Copy the build output into the embed directory (repo root)
cp -r frontend/build/* backend/pkg/embed/frontend/

# 3. Backend (Go version from backend/go.mod; the `taskw` wrapper pins it)
cd backend && CGO_ENABLED=0 go build -o ../console-api ./cmd/api
```

If `bun install` fails on the root package's `prepare` script (`lefthook install`
requires git), or on `isolated-vm`'s native build (requires python3/make/g++), install with
`--ignore-scripts` instead — like the Dockerfile does. The frontend build does not need
either; `isolated-vm`'s native binary is only loaded at runtime in server-side code paths.

Note: `backend/pkg/embed/frontend/` is git-ignored — cleaning your working tree removes the
assets, and the build fails until step 2 is repeated.

## Troubleshooting

- **`cannot embed directory frontend: contains no embeddable files`** — the embed directory
  was empty at build time. Locally: re-run step 2 above. In Docker: the `frontend` stage
  failed or its output path changed (`frontend/build/` per `distPath.root` in
  `frontend/rsbuild.config.ts`).
- **Frontend changes not showing up** — stale assets in a local `backend/pkg/embed/frontend/`;
  delete the directory contents and re-copy. Docker builds are immune (`.dockerignore`
  excludes that directory).
- **Go version mismatch** — `backend/go.mod` declares the required toolchain (`go` directive,
  currently 1.26.6). The `golang:1.26-alpine` stage tracks the latest 1.26 patch release and
  satisfies it; make sure `go` is at least that version when building locally.
- **Container starts but cannot reach brokers** — usually an advertised-listener problem
  (see above), or TLS/SASL mismatches; enable debug logs via `LOGGING_LEVEL=debug`.
- **No cluster at hand for a quick smoke test** — the HTTP server only binds after the
  Kafka connectivity check passes. To start and serve the UI without a reachable broker,
  set `KAFKA_STARTUP_ESTABLISHCONNECTIONEAGERLY=false` (maps to
  `kafka.startup.establishConnectionEagerly`, see `testKafkaConnectivity` in
  `backend/pkg/console/service.go`); API calls will still fail. Note that
  `KAFKA_BROKERS` must still be set to something — config validation rejects an empty
  broker list (`Kafka.Validate()`) — but the address does not need to be reachable.
