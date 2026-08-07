# Langfuse Lite Railway Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a Railway marketplace template ("Langfuse Lite") that deploys Langfuse v4.6.0 in 3 services + 1 bucket, with CI that auto-bumps upstream releases behind a gating smoke test.

**Architecture:** A wrapper Docker image runs Langfuse web + worker + a localhost Redis in one container (worker on internal port 3030, gated on web health so migrations finish first; launcher waits for Postgres/ClickHouse TCP readiness before starting anything). Template services deploy from one-line Dockerfiles in this repo (Railway update notifications only work for repo-based services). Postgres uses Railway's own postgres-ssl image; ClickHouse is single-node upstream with a locked-down `default` user; S3 is a Railway bucket (MinIO fallback if buckets can't ship in templates — resolved empirically in Task 0).

**Tech Stack:** Docker (Alpine base), bash, docker compose, GitHub Actions, GHCR, Railway (MCP tools + dashboard template composer).

**Revision note:** This plan was revised after a two-reviewer gate (independent critic subagent + cross-model Opus review). Both proved the original bump-CI trigger mechanism unworkable and the UTC assertion wrong; the critic additionally caught a web/worker port collision. All accepted findings are folded in below.

**Ingestion-mode decision (user, 2026-08-07):** Langfuse v4 defaults
`LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only`, which **rejects the legacy
`trace-create` batch event** on `/api/public/ingestion` (that endpoint now
accepts only `score-create` and `sdk-log`). The template ships **v4-native**:
keep the upstream default, set no migration ENV overrides, and require modern
SDKs (Python ≥4.7.0 / JS ≥5.4.0). Consequences that override earlier text in
this plan wherever they conflict:
- The smoke test ingests via OTLP: `POST /api/public/otel/v1/traces`, with
  header `x-langfuse-ingestion-version: 4`, basic auth `pk:sk`, OTLP/JSON body.
  Verified present in the image at
  `/app/web/.next/server/pages/api/public/otel/v1/traces.js`.
- The OTLP trace id (32 hex chars) is the id to poll on
  `GET /api/public/traces/<id>`.
- `image/Dockerfile` carries **no** `LANGFUSE_MIGRATION_V4_*` ENV lines.
- README states the minimum SDK versions.

## Global Constraints

- Never commit or push to `main` directly — all work on the existing branch `design/langfuse-lite-template`, integrated via PR. (One sanctioned exception: Task 5 bootstraps `main` from the reviewed branch because the repo has no `main` yet.)
- Repo git config already sets commit email `55049+elleryfamilia@users.noreply.github.com` (public repo; GitHub email privacy).
- Pinned versions (single sources of truth, exact values today): `ARG LANGFUSE_VERSION=4.6.0` in `image/Dockerfile`; `clickhouse/clickhouse-server:25.12` in `services/clickhouse/Dockerfile`; `ghcr.io/railwayapp-templates/postgres-ssl:17` in `services/postgres/Dockerfile`.
- Image name: `ghcr.io/elleryfamilia/langfuse-lite`. Tags mirror Docker Hub's Langfuse tags (no `v` prefix): `4.6.0`. Release tags are **create-only** — CI must never overwrite an existing version tag.
- No secrets in the repo, ever; no extra CI secrets either (`GITHUB_TOKEN` only — the bump flow uses the `workflow_dispatch` exception, not a PAT). Smoke-test credentials are throwaway literals that only bind to localhost stacks.
- Both upstream Langfuse images are Alpine (bash 5.x via apk), run as uid 1001, workdir `/app`, PID1 `dumb-init`. Verified 2026-08-07: web image `/app` has `node_modules/ packages/ web/ next.config.mjs package.json` and **no** `worker/`; worker image `/app` contains exactly `worker/` — the trees do not collide. Web ships `ENV PORT=3000`; worker ships `ENV PORT=3030` and its process binds `env.PORT` — in the merged image the worker MUST get `PORT=3030` explicitly or both bind 3000 and crash-loop.
- The user runs macOS/arm64 locally; CI (ubuntu) publishes amd64 images. Local `docker build` of `services/langfuse` will emit a platform warning — expected, ignored.
- GitHub Actions ground truth (verified against GitHub docs): pushes made with `GITHUB_TOKEN` do NOT trigger `push` workflows; PRs created with `GITHUB_TOKEN` create `pull_request` runs only in an approval-required state. The documented exceptions are `workflow_dispatch` and `repository_dispatch` — the bump flow relies on `workflow_dispatch`.

---

### Task 0: Bucket-in-template spike — ✅ DONE 2026-08-07. **Outcome: BUCKET.**

> Verified in the template composer: `Add New → Bucket` adds a "Railway Provided"
> bucket ("No config required") whose Credentials tab exposes Endpoint URL,
> Region, Bucket Name, Access Key ID, Secret Access Key — each with a "Copy
> Reference" button, each "Populated after deploy". **The MinIO fallback is not
> needed anywhere in this plan; ignore every MinIO-fallback branch below except
> in `compose.smoke.yml`, where MinIO remains the local S3 stand-in.** README
> copy stays "3 services + a storage bucket".
>
> Cleanup note: the throwaway draft template is named `swift-warm` in Ellery's
> workspace. Deleting it requires a 2FA code, so it was left in place — Ellery
> deletes it (do NOT touch `high-vast`, which is pre-existing and unrelated).

<details><summary>Original spike steps (completed)</summary>

**Files:** none (Railway dashboard)

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded yes/no — "can a Railway template contain a bucket?" README wording (Task 4), the app's S3 wiring (Tasks 9–10), and the marketplace copy all branch on this. Record the answer in `docs/superpowers/specs/2026-08-07-langfuse-lite-railway-template-design.md` (Risks table) immediately.

- [ ] **Step 1: Open the template composer and try to add a bucket**

In the Railway dashboard: workspace settings → Templates → New Template. Check the `Add New` menu (and the `CMD+K` palette) for a Bucket option alongside services/volumes.
- Bucket option exists → add one, confirm it saves in the draft template, then discard the draft. **Outcome: BUCKET.**
- No bucket option → discard the draft. **Outcome: MINIO** (template ships MinIO as a 4th service; the "3 services + bucket" copy in Task 4 becomes "4 services").

- [ ] **Step 2: Record the outcome**

Update the spec's Risks table row ("Buckets can't be included in published templates") with what was observed, and note the outcome at the top of Task 4 and Task 10 below (edit this plan file). Commit:

```bash
git add -A && git commit -m "docs: record bucket-in-template spike outcome"
```

</details>

---

### Task 1: Smoke-test harness (the failing test)

**Files:**
- Create: `compose.smoke.yml`
- Create: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/smoke-test.sh` — exit 0 on pass; honors env `IMAGE_TAG` (prebuilt app image name; when unset, compose builds `./image`). App service name `app`, web on `localhost:3000`. Smoke API keys are the literals `pk-lf-smoke-1234567890` / `sk-lf-smoke-1234567890` (obviously fake, but verify GitHub push protection doesn't flag them at Task 5). Task 6's CI and Task 9's cloud verify reuse the ingest/query pattern.

- [ ] **Step 1: Write `compose.smoke.yml`**

Notes: `TZ`/`PGTZ` on Postgres match upstream Langfuse's own compose (without them postgres-ssl reports `Etc/UTC`). Healthchecks + `service_healthy` conditions mirror upstream — `depends_on` alone waits only for container start, and the app entrypoint migrates immediately. Postgres gets a named volume so the PGDATA-subdirectory path (the reason we chose postgres-ssl) is actually exercised. S3 prefixes are set so the smoke stack covers the same prefix handling the template uses.

```yaml
services:
  app:
    image: "${IMAGE_TAG:-langfuse-lite:dev}"
    build: ./image
    depends_on:
      postgres: { condition: service_healthy }
      clickhouse: { condition: service_healthy }
      minio: { condition: service_started }
    ports: ["3000:3000"]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/langfuse
      SALT: smokesalt
      ENCRYPTION_KEY: "0000000000000000000000000000000000000000000000000000000000000000"
      NEXTAUTH_SECRET: smokesecret
      NEXTAUTH_URL: http://localhost:3000
      CLICKHOUSE_URL: http://clickhouse:8123
      CLICKHOUSE_MIGRATION_URL: clickhouse://clickhouse:9000
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: clickhouse
      CLICKHOUSE_CLUSTER_ENABLED: "false"
      REDIS_CONNECTION_STRING: redis://127.0.0.1:6379
      LANGFUSE_S3_EVENT_UPLOAD_BUCKET: langfuse
      LANGFUSE_S3_EVENT_UPLOAD_PREFIX: events/
      LANGFUSE_S3_EVENT_UPLOAD_REGION: auto
      LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: minio
      LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: miniosecret
      LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: http://minio:9000
      LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_S3_MEDIA_UPLOAD_BUCKET: langfuse
      LANGFUSE_S3_MEDIA_UPLOAD_PREFIX: media/
      LANGFUSE_S3_MEDIA_UPLOAD_REGION: auto
      LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID: minio
      LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY: miniosecret
      LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT: http://minio:9000
      LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_INIT_ORG_ID: smoke-org
      LANGFUSE_INIT_PROJECT_ID: smoke-project
      LANGFUSE_INIT_PROJECT_PUBLIC_KEY: pk-lf-smoke-1234567890
      LANGFUSE_INIT_PROJECT_SECRET_KEY: sk-lf-smoke-1234567890
      LANGFUSE_INIT_USER_EMAIL: smoke@example.com
      LANGFUSE_INIT_USER_NAME: Smoke
      LANGFUSE_INIT_USER_PASSWORD: smokePassw0rd!
  postgres:
    image: ghcr.io/railwayapp-templates/postgres-ssl:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: langfuse
      PGDATA: /var/lib/postgresql/data/pgdata
      TZ: UTC
      PGTZ: UTC
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      timeout: 3s
      retries: 30
  clickhouse:
    image: clickhouse/clickhouse-server:25.12
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: clickhouse
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:8123/ping"]
      interval: 3s
      timeout: 3s
      retries: 30
  minio:
    image: cgr.dev/chainguard/minio
    entrypoint: sh -c 'mkdir -p /data/langfuse && minio server --address ":9000" /data'
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: miniosecret
volumes:
  pgdata:
```

(Note: `cgr.dev/chainguard/minio` publishes only a moving `:latest` on the free tier. At implementation, check whether `minio/minio` has a current `RELEASE.*` tag — `docker manifest inspect minio/minio:<tag>` — and pin that instead if so, adjusting the entrypoint to MinIO's standard `server /data` form. If pinning is impractical, keep chainguard and accept the drift; the harness still gates on behavior.)

- [ ] **Step 2: Write `scripts/smoke-test.sh`**

Notes: trace ID via python3 (uuidgen isn't guaranteed on ubuntu runners); UTC grep accepts `Etc/UTC`; ingestion response body is captured and asserted (a 207 with per-event errors would otherwise surface 3 minutes later as a misleading timeout); 600 s health budget (postgres-ssl initdb + SSL certs + pgbackrest init + both migration sets on a cold stack).

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f compose.smoke.yml)
PK=pk-lf-smoke-1234567890
SK=sk-lf-smoke-1234567890

fail() { echo "FAIL: $1"; "${COMPOSE[@]}" logs app | tail -150; exit 1; }
cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ -n "${IMAGE_TAG:-}" ]; then
  "${COMPOSE[@]}" up -d --no-build
else
  "${COMPOSE[@]}" up -d --build
fi

echo "waiting for app health (up to 600s)..."
ok=""
for _ in $(seq 1 300); do
  if curl -sf http://localhost:3000/api/public/health >/dev/null; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || fail "health timeout"

TRACE_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INGEST_RESPONSE=$(curl -s -u "$PK:$SK" -H 'Content-Type: application/json' \
  -X POST http://localhost:3000/api/public/ingestion \
  -d "{\"batch\":[{\"id\":\"evt-$TRACE_ID\",\"type\":\"trace-create\",\"timestamp\":\"$NOW\",\"body\":{\"id\":\"$TRACE_ID\",\"name\":\"smoke-trace\"}}]}")
echo "ingestion response: $INGEST_RESPONSE"
echo "$INGEST_RESPONSE" | python3 -c 'import json,sys; r=json.load(sys.stdin); errs=r.get("errors",[]); sys.exit(1 if errs else 0)' \
  || fail "ingestion API returned per-event errors (401 means LANGFUSE_INIT_* bootstrap did not run)"

echo "waiting for trace to be queryable (web -> redis -> worker -> s3 -> clickhouse)..."
ok=""
for _ in $(seq 1 90); do
  if curl -sf -u "$PK:$SK" "http://localhost:3000/api/public/traces/$TRACE_ID" >/dev/null; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || fail "trace never became queryable"

PGTZ_ACTUAL=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d langfuse -tAc "show timezone")
echo "$PGTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "postgres timezone is '$PGTZ_ACTUAL', not UTC"
CHTZ_ACTUAL=$("${COMPOSE[@]}" exec -T clickhouse clickhouse-client --user clickhouse --password clickhouse --query "SELECT timezone()")
echo "$CHTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "clickhouse timezone is '$CHTZ_ACTUAL', not UTC"

echo "SMOKE PASS"
```

- [ ] **Step 3: Make executable and run to verify it fails for the right reason**

Run: `chmod +x scripts/smoke-test.sh && ./scripts/smoke-test.sh`
Expected: FAIL — compose cannot build `./image` (directory does not exist yet). This is the failing test for Task 2.

- [ ] **Step 4: Commit**

```bash
git add compose.smoke.yml scripts/smoke-test.sh
git commit -m "test: add end-to-end smoke harness for the lite stack"
```

---

### Task 2: Wrapper image (web + worker + Redis in one container)

**Files:**
- Create: `image/Dockerfile`
- Create: `image/launcher.sh`
- Test: `scripts/smoke-test.sh` (from Task 1)

**Interfaces:**
- Consumes: smoke harness from Task 1.
- Produces: buildable image context at `image/` with `ARG LANGFUSE_VERSION=4.6.0` on line 1 of `image/Dockerfile` (Tasks 6/7 sed this exact line). Container serves HTTP on port 3000 (web); worker runs internally on 3030; expects the env contract listed in `compose.smoke.yml`.

- [ ] **Step 1: Write `image/launcher.sh`**

Process model: wait for Postgres + ClickHouse TCP readiness (Railway deploys all services in parallel; a crash-before-ready burns the healthcheck window) → start Redis → start web (upstream entrypoint migrates then serves, bound to `::` so Railway's IPv6 private network and the loopback health gate both work) → start worker only after web is healthy, with its own `PORT=3030`. Any process exiting takes the container down (nonzero) so Railway restarts it; a graceful TERM exits 0.

```bash
#!/bin/bash
set -uo pipefail

# --- wait for backing stores (parse host:port from the URLs) ---
wait_tcp() { # host port label
  local i
  for i in $(seq 1 150); do
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&- 3<&-; echo "$3 reachable"; return 0; }
    sleep 2
  done
  echo "FATAL: $3 ($1:$2) unreachable after 300s"; exit 1
}
if [[ "${DATABASE_URL:-}" =~ @([^:/?]+)(:([0-9]+))? ]]; then
  wait_tcp "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-5432}" "postgres"
fi
if [[ "${CLICKHOUSE_URL:-}" =~ ^https?://([^:/?]+)(:([0-9]+))? ]]; then
  wait_tcp "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-8123}" "clickhouse"
fi

TERMED=""
shutdown() { TERMED=1; kill -TERM ${REDIS_PID:-} ${WORKER_PID:-} ${WEB_PID:-} 2>/dev/null || true; }
trap shutdown TERM INT

redis-server --port 6379 --bind 127.0.0.1 --save '' --appendonly no \
  --maxmemory-policy noeviction --dir /var/lib/redis-eph &
REDIS_PID=$!

WEB_PORT="${PORT:-3000}"
(
  cd /app
  export HOSTNAME=::   # bind IPv6 dual-stack: Railway private net is IPv6; loopback probe still works
  exec ./web/entrypoint.sh node ./web/server.js --keepAliveTimeout 110000
) &
WEB_PID=$!

(
  until wget -q -O /dev/null "http://127.0.0.1:${WEB_PORT}/api/public/health" 2>/dev/null \
     || wget -q -O /dev/null "http://[::1]:${WEB_PORT}/api/public/health" 2>/dev/null; do
    sleep 2
  done
  cd /app
  export PORT=3030   # worker binds env.PORT; without this it collides with web on 3000
  exec ./worker/entrypoint.sh node worker/dist/index.js
) &
WORKER_PID=$!

wait -n "$REDIS_PID" "$WORKER_PID" "$WEB_PID"
CODE=$?
shutdown
wait
[ -n "$TERMED" ] && exit 0
exit $CODE
```

- [ ] **Step 2: Write `image/Dockerfile`**

The worker image's `/app` contains exactly one entry (`worker/`) and the web image's `/app` has no `worker/` — so the worker copies into `/app/worker` with zero collisions and zero path drift (its pnpm-deployed `node_modules` and generated Prisma client stay at the paths they were built for). Ownership `1001:1001` matches both images' uid/gid (web chowns its files `nextjs:nodejs`, gid 1001 — not `nogroup`). `CMD []` prevents the base image's inherited CMD being appended to the launcher.

```dockerfile
ARG LANGFUSE_VERSION=4.6.0
FROM langfuse/langfuse-worker:${LANGFUSE_VERSION} AS worker

FROM langfuse/langfuse:${LANGFUSE_VERSION}
USER root
RUN apk add --no-cache bash redis \
    && mkdir -p /var/lib/redis-eph \
    && chown 1001:1001 /var/lib/redis-eph
COPY --from=worker --chown=1001:1001 /app/worker /app/worker
COPY --chown=1001:1001 launcher.sh /launcher.sh
RUN chmod +x /launcher.sh
USER nextjs
ENV PORT=3000
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--", "/launcher.sh"]
CMD []
```

- [ ] **Step 3: Verify the layout assumption before testing**

Run:
```bash
docker build -t langfuse-lite:dev image/
docker run --rm --entrypoint sh langfuse-lite:dev -c 'ls -la /app | head; ls /app/worker | head; which bash redis-server'
```
Expected: `/app` shows both `web/` and `worker/`; bash and redis-server resolve.

- [ ] **Step 4: Run the smoke test**

Run: `./scripts/smoke-test.sh`
Expected: `SMOKE PASS` (first run downloads images; allow ~10 minutes). If it fails, read the `logs app` tail the script prints: migration errors mean DB connectivity/env; "unreachable after 300s" means the readiness gate itself — check compose healthchecks.

- [ ] **Step 5: Commit**

```bash
git add image/
git commit -m "feat: combined web+worker+redis wrapper image passing smoke test"
```

---

### Task 3: Template service Dockerfiles (+ ClickHouse lockdown)

**Files:**
- Create: `services/langfuse/Dockerfile`
- Create: `services/clickhouse/Dockerfile`
- Create: `services/clickhouse/lockdown.xml`
- Create: `services/postgres/Dockerfile`
- Modify: `compose.smoke.yml` (postgres/clickhouse services switch to building `services/*` for parity)

**Interfaces:**
- Consumes: the GHCR image name/tag contract from Global Constraints (image does not exist remotely yet — local verification tags a local build with that name, then removes the tag).
- Produces: the three root directories the Railway template's services point at. Task 7's bump sed targets the `FROM` line of `services/langfuse/Dockerfile` and the tag in `services/clickhouse/Dockerfile`.

- [ ] **Step 1: Write the Dockerfiles**

`services/langfuse/Dockerfile`:
```dockerfile
FROM ghcr.io/elleryfamilia/langfuse-lite:4.6.0
```

`services/clickhouse/Dockerfile`:
```dockerfile
FROM clickhouse/clickhouse-server:25.12
COPY lockdown.xml /etc/clickhouse-server/users.d/lockdown.xml
```

`services/clickhouse/lockdown.xml` — the official entrypoint creates `CLICKHOUSE_USER` but leaves the passwordless `default` user reachable; restrict it to loopback so it cannot be used across Railway's private network:
```xml
<clickhouse>
  <users>
    <default>
      <networks replace="replace">
        <ip>127.0.0.1</ip>
        <ip>::1</ip>
      </networks>
    </default>
  </users>
</clickhouse>
```

`services/postgres/Dockerfile`:
```dockerfile
FROM ghcr.io/railwayapp-templates/postgres-ssl:17
```

- [ ] **Step 2: Point the smoke stack at these build contexts (parity)**

In `compose.smoke.yml`, replace the postgres/clickhouse `image:` lines:
```yaml
  postgres:
    build: ./services/postgres
    # (environment/volumes/healthcheck unchanged)
  clickhouse:
    build: ./services/clickhouse
    # (environment/healthcheck unchanged)
```

- [ ] **Step 3: Verify builds and rerun the smoke test**

Run:
```bash
docker tag langfuse-lite:dev ghcr.io/elleryfamilia/langfuse-lite:4.6.0
docker build services/langfuse/
docker rmi ghcr.io/elleryfamilia/langfuse-lite:4.6.0   # never leave a local arm64 build wearing the canonical tag
./scripts/smoke-test.sh
```
Expected: langfuse service builds from the local tag; smoke passes with the lockdown in place (the app connects as `clickhouse`, not `default`, so nothing changes functionally).

- [ ] **Step 4: Commit**

```bash
git add services/ compose.smoke.yml
git commit -m "feat: repo-based service Dockerfiles with ClickHouse default-user lockdown"
```

---

### Task 4: README / template overview

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: Task 0's bucket outcome (adjust "3 services + a storage bucket" to "4 services" if MINIO); spec decisions.
- Produces: the exact line `Current Langfuse version: 4.6.0` (Task 7's bump sed rewrites it — it is the ONLY versioned line; dependency bullets deliberately carry no version numbers so infra bumps can't stale them); overview copy pasted into the Railway template at Task 10.

- [ ] **Step 1: Write `README.md`**

Follow Railway's required overview structure. Content requirements (write full prose):

```markdown
# Deploy and Host Langfuse Lite on Railway

Langfuse is an open-source LLM engineering platform: tracing, evals, prompt
management, and metrics. **Langfuse Lite** deploys it in just 3 services + a
storage bucket — about half the footprint of a full production topology —
for pre-production environments where cost matters more than high
availability. This is an unofficial community template, not affiliated with
Langfuse GmbH.

Current Langfuse version: 4.6.0

## About Hosting Langfuse Lite

A full Langfuse v3/v4 self-host needs six components: web app, worker,
Postgres, ClickHouse, Redis, and S3-compatible blob storage. Langfuse Lite
keeps all six functions but co-locates web, worker, and Redis in a single
container (the worker waits for web so database migrations finish first;
Redis is in-memory only). Postgres runs Railway's own postgres-ssl image
with a volume; ClickHouse runs single-node with a volume; blob storage is a
Railway bucket. Upgrades ship as pull requests in this repo — merging a
version bump updates new deploys and notifies existing ones via Railway's
template update flow.

**After deploying: open the app URL and create your account immediately.**
Sign-up is open on a fresh instance — the first person to register owns it.

## Common Use Cases

- Tracing and debugging LLM apps during development
- Staging/preview environments that mirror production observability
- Personal projects and prototypes where a 6-service stack is overkill
- Evaluating Langfuse before committing to a production deployment

## Dependencies for Langfuse Lite Hosting

- Langfuse web + worker (upstream images, combined; version pinned in `image/Dockerfile`)
  — runs v4-native ingestion, so instrument with Python SDK ≥4.7.0 / JS ≥5.4.0
  (or native OpenTelemetry); older SDKs are rejected by upstream's default
  `events_only` write mode
- PostgreSQL (Railway postgres-ssl; pinned in `services/postgres/Dockerfile`)
- ClickHouse single node (pinned in `services/clickhouse/Dockerfile`)
- Redis (embedded, ephemeral)
- Railway bucket (S3-compatible)

### Deployment Dependencies

- https://langfuse.com/self-hosting
- https://github.com/elleryfamilia/langfuse-lite-railway (this template's source)
- https://ghcr.io/elleryfamilia/langfuse-lite (prebuilt image)

### Implementation Details

**Not for production.** No HA, single-node ClickHouse, ephemeral Redis queue
(a redeploy can drop queued-but-unprocessed events), no backups. Plan
roughly 2 GB RAM for the app service. Infrastructure pins (ClickHouse,
Postgres) are re-checked only when a Langfuse release bumps — they do not
self-update. For production use Langfuse Cloud or a full 6-service template.

### Why Deploy Langfuse Lite on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway
will host your infrastructure so you don't have to deal with configuration,
while allowing you to vertically and horizontally scale it.

By deploying Langfuse Lite on Railway, you get full LLM observability for
your pre-production apps at the lowest service footprint available.

## Development

- `./scripts/smoke-test.sh` — full local end-to-end: builds the wrapper
  image, boots Postgres + ClickHouse + MinIO, ingests a trace, and verifies
  it becomes queryable.
- A scheduled GitHub Action watches Langfuse releases and opens bump PRs;
  CI builds, smoke-tests, and publishes the exact-version image before the
  PR can merge. Merging is the release action.
```

(If Task 0's outcome was MINIO: change "3 services + a storage bucket" to "4 services", and the bucket bullet to "MinIO (S3-compatible, volume-backed)".)

- [ ] **Step 2: Verify the version line matches the pin**

Run: `grep -q "Current Langfuse version: $(sed -n 's/^ARG LANGFUSE_VERSION=//p' image/Dockerfile)" README.md && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: template overview README in Railway marketplace format"
```

---

### Task 5: Publish repo to GitHub

**Files:**
- Create: `LICENSE` (MIT — Railway's kickback program targets open-source templates)
- Modify: `.gitignore` (append — the working tree already ignores `.loadout/` and `.cursor/` entries; do NOT overwrite)

**Interfaces:**
- Consumes: all prior tasks committed on `design/langfuse-lite-template`.
- Produces: public repo `elleryfamilia/langfuse-lite-railway`, `main` bootstrapped, Actions allowed to create PRs. CI (Task 6) and Railway services (Task 9) depend on it.

- [ ] **Step 1: LICENSE + .gitignore, commit**

```bash
curl -sf https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt \
  | sed "s/{{ year }}/2026/; s/{{ organization }}/Ellery Familia/" > LICENSE
# fallback if that URL 404s: paste the standard MIT text with "Copyright (c) 2026 Ellery Familia"
printf '.DS_Store\n*.log\n.env\n.env.*\n*.pem\n' >> .gitignore
git add LICENSE .gitignore && git commit -m "chore: add MIT license and gitignore entries"
```

- [ ] **Step 2: Create the public repo and push the branch**

```bash
gh repo create elleryfamilia/langfuse-lite-railway --public \
  --description "Langfuse Lite — minimal Langfuse deployment template for Railway" \
  --source . --push
```
If push protection blocks on the smoke `pk-lf-`/`sk-lf-` literals, they are documented throwaway values — use the "allow" URL GitHub prints, or restructure the literals (e.g., build them in the script from parts) and re-commit.

- [ ] **Step 3: Bootstrap `main`**

Rule: if `main` does not exist yet, creating it from the reviewed branch IS the initial publish (the one sanctioned direct write — there is no history to protect). Once `main` exists, all subsequent changes reach it via PR only.

```bash
git push origin design/langfuse-lite-template:refs/heads/main
gh repo edit elleryfamilia/langfuse-lite-railway --default-branch main
```

- [ ] **Step 4: Allow Actions to create PRs (required for Task 7)**

`pull-requests: write` in the workflow is necessary but not sufficient — this is a separate repo toggle:
```bash
gh api -X PUT repos/elleryfamilia/langfuse-lite-railway/actions/permissions/workflow \
  -f default_workflow_permissions=write -F can_approve_pull_request_reviews=true
```

- [ ] **Step 5: Verify**

Run: `gh repo view elleryfamilia/langfuse-lite-railway --json defaultBranchRef,visibility --jq '.defaultBranchRef.name + " " + .visibility'`
Expected: `main PUBLIC`

---

### Task 6: CI — build, smoke-test, publish (`build.yml`)

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `scripts/smoke-test.sh` `IMAGE_TAG` contract (Task 1); `ARG LANGFUSE_VERSION` pin line (Task 2).
- Produces: GHCR package `ghcr.io/elleryfamilia/langfuse-lite:<version>`. Publish paths: (a) `workflow_dispatch` with `publish=true` — used by the bump flow (Task 7) via the documented `workflow_dispatch` exception to GITHUB_TOKEN trigger suppression; (b) push to `main` — verify-or-publish rescue, which also performs the initial publish after Task 8's merge. Release tags are create-only. PR runs build+smoke only; fork PRs get a read-only token and skip publish structurally.

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: build
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      publish:
        description: "Push the exact-version tag to GHCR after a green smoke test"
        type: boolean
        default: false

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/elleryfamilia/langfuse-lite

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - id: ver
        name: Read pinned Langfuse version
        run: echo "version=$(sed -n 's/^ARG LANGFUSE_VERSION=//p' image/Dockerfile)" >> "$GITHUB_OUTPUT"

      - name: Guard against upstream start-command drift
        run: |
          docker pull -q "langfuse/langfuse:${{ steps.ver.outputs.version }}"
          CMD=$(docker inspect "langfuse/langfuse:${{ steps.ver.outputs.version }}" --format '{{json .Config.Cmd}}')
          echo "$CMD" | grep -q 'web/server.js --keepAliveTimeout 110000' \
            || { echo "Upstream web CMD changed; update image/launcher.sh to match: $CMD"; exit 1; }

      - name: Build wrapper image
        run: docker build -t "$IMAGE:${{ steps.ver.outputs.version }}" image/

      - name: Smoke test the built image
        run: IMAGE_TAG="$IMAGE:${{ steps.ver.outputs.version }}" ./scripts/smoke-test.sh

      - name: Log in to GHCR
        if: github.repository == 'elleryfamilia/langfuse-lite-railway' && (github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.publish))
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Publish exact-version tag (create-only)
        if: github.repository == 'elleryfamilia/langfuse-lite-railway' && (github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.publish))
        run: |
          V="${{ steps.ver.outputs.version }}"
          if docker manifest inspect "$IMAGE:$V" >/dev/null 2>&1; then
            echo "tag $V already exists on GHCR — leaving it untouched"
          else
            docker push "$IMAGE:$V"
          fi
```

- [ ] **Step 2: Push and open the integration PR (CI's first live run)**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build, smoke-test, and create-only publish of the wrapper image"
git push -u origin design/langfuse-lite-template
gh pr create --base main --head design/langfuse-lite-template \
  --title "feat: Langfuse Lite v1" \
  --body "Wrapper image, service Dockerfiles, smoke harness, CI, README, design docs."
gh run watch --exit-status "$(gh run list --branch design/langfuse-lite-template --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: the `pull_request` run goes green (build + smoke on ubuntu; no publish on PR events). Leave the PR open — Task 7 adds one more commit to it.

---

### Task 7: CI — scheduled version bump (`bump.yml`)

**Files:**
- Create: `.github/workflows/bump.yml`

**Interfaces:**
- Consumes: pin lines from Tasks 2/3/4; `build.yml`'s `workflow_dispatch` publish path (Task 6); the repo toggle from Task 5 Step 4.
- Produces: branches `bump/langfuse-<version>` + PRs, each with a dispatched build run (green check on the PR's head SHA) that publishes the new tag BEFORE merge. Note: the PR's own `pull_request` run will sit in "approval-required" state (GITHUB_TOKEN-created PR) — the dispatched run is the real gate; the PR body says so.

- [ ] **Step 1: Write `.github/workflows/bump.yml`**

```yaml
name: bump
on:
  schedule:
    - cron: "23 9 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write
  actions: write

jobs:
  bump:
    runs-on: ubuntu-latest
    if: github.repository == 'elleryfamilia/langfuse-lite-railway'
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4

      - name: Compare pinned vs latest upstream, open gated bump PR
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          LATEST=$(gh api repos/langfuse/langfuse/releases/latest --jq .tag_name | sed 's/^v//')
          CURRENT=$(sed -n 's/^ARG LANGFUSE_VERSION=//p' image/Dockerfile)

          # Guards: non-empty, strict semver, strictly newer than current
          echo "$LATEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "no valid latest release ('$LATEST'); skipping"; exit 0; }
          [ "$LATEST" = "$CURRENT" ] && { echo "already at $CURRENT"; exit 0; }
          [ "$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | sort -V | tail -1)" = "$LATEST" ] || { echo "latest ($LATEST) is older than pin ($CURRENT); skipping"; exit 0; }

          # Idempotency: a bump branch for this version already exists
          git ls-remote --exit-code --heads origin "bump/langfuse-$LATEST" >/dev/null 2>&1 \
            && { echo "bump/langfuse-$LATEST already open"; exit 0; }

          git checkout -b "bump/langfuse-$LATEST"
          sed -i "s/^ARG LANGFUSE_VERSION=.*/ARG LANGFUSE_VERSION=$LATEST/" image/Dockerfile
          sed -i "s#^FROM ghcr.io/elleryfamilia/langfuse-lite:.*#FROM ghcr.io/elleryfamilia/langfuse-lite:$LATEST#" services/langfuse/Dockerfile
          sed -i "s/^Current Langfuse version: .*/Current Langfuse version: $LATEST/" README.md

          # Track upstream's ClickHouse pin only if the tag verifiably exists
          CH=$(curl -sf "https://raw.githubusercontent.com/langfuse/langfuse/v$LATEST/docker-compose.yml" \
            | sed -n 's/.*clickhouse-server:\([0-9][0-9.]*\).*/\1/p' | head -1) || CH=""
          if [ -n "$CH" ] && docker manifest inspect "clickhouse/clickhouse-server:$CH" >/dev/null 2>&1; then
            sed -i "s#^FROM clickhouse/clickhouse-server:.*#FROM clickhouse/clickhouse-server:$CH#" services/clickhouse/Dockerfile
          fi

          git config user.name "langfuse-lite-bot"
          git config user.email "55049+elleryfamilia@users.noreply.github.com"
          git commit -am "feat: bump Langfuse to $LATEST"
          git push -u origin "bump/langfuse-$LATEST"

          # GITHUB_TOKEN pushes trigger nothing; workflow_dispatch is the documented exception.
          gh workflow run build.yml --ref "bump/langfuse-$LATEST" -f publish=true

          gh pr create --base main \
            --title "feat: bump Langfuse to $LATEST" \
            --body "Automated upstream bump. A dispatched build run on this branch builds, smoke-tests, and publishes \`$LATEST\` to GHCR — merge only when that run is green. (This PR's own pull_request check may sit in 'approval-required'; the dispatched run on the head SHA is the gate.)"
```

- [ ] **Step 2: Push to the open PR**

```bash
git add .github/workflows/bump.yml
git commit -m "ci: scheduled upstream release bump PRs (dispatch-gated)"
git push
gh run watch --exit-status "$(gh run list --branch design/langfuse-lite-template --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: green `pull_request` run. `bump.yml` cannot be exercised yet — `schedule`/`workflow_dispatch` only work once the file is on the default branch. Its dry run happens in Task 8 Step 4.

---

### Task 8: Merge, initial publish, bump dry-run

**Files:** none

**Interfaces:**
- Consumes: green PR from Tasks 6–7.
- Produces: everything on `main`; `ghcr.io/elleryfamilia/langfuse-lite:4.6.0` published (amd64, from CI) and public; bump automation verified live. Railway (Task 9) can now build `services/langfuse` for real.

- [ ] **Step 1: Merge the PR**

```bash
gh pr merge --squash "$(gh pr list --head design/langfuse-lite-template --json number --jq '.[0].number')"
gh run watch --exit-status "$(gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: the push-to-main run goes green and its create-only publish step pushes `4.6.0` (first publish — the tag doesn't exist yet).

- [ ] **Step 2: Make the GHCR package public**

First publish lands private. Check and fix:
```bash
gh api "user/packages/container/langfuse-lite" --jq .visibility
```
If `private`: open https://github.com/users/elleryfamilia/packages/container/langfuse-lite/settings → Danger Zone → Change visibility → Public. If the `gh api` call 403s, refresh scopes: `gh auth refresh -s read:packages`.
Expected after fix: `public`.

- [ ] **Step 3: Verify anonymous pull and the services build**

```bash
docker logout ghcr.io
docker manifest inspect ghcr.io/elleryfamilia/langfuse-lite:4.6.0
docker build services/langfuse/
```
Expected: manifest resolves without auth (amd64); the build pulls the real GHCR image (platform warning on arm64 Mac is expected).

- [ ] **Step 4: Bump dry-run**

```bash
gh workflow run bump
sleep 20
gh run watch --exit-status "$(gh run list --workflow bump --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: green run logging `already at 4.6.0` (or, if upstream released since: a `bump/langfuse-*` PR plus a dispatched build run — watch that run go green, confirm the new tag on GHCR, then merge or close the PR deliberately).

- [ ] **Step 5: Sync local**

```bash
git checkout main && git pull
git checkout design/langfuse-lite-template && git merge main
```

---

### Task 9: Live test project on Railway

**Files:** none (Railway MCP operations)

**Interfaces:**
- Consumes: `main` deployable end-to-end (Task 8); Task 0's bucket outcome.
- Produces: a working Railway project `langfuse-lite-test` proving the topology on real infrastructure; kept as the source for template conversion in Task 10.

- [ ] **Step 1: Create project, bucket, and the three services (Railway MCP)**

Order matters — the app's variables reference the others, and the domain must exist before `NEXTAUTH_URL` resolves:
1. `create_project` name `langfuse-lite-test`
2. `create_bucket` name `langfuse-data` (skip if Task 0's outcome was MINIO — instead create a MinIO service: image `cgr.dev/chainguard/minio`, volume at `/data`, start command `sh -c 'mkdir -p /data/langfuse && minio server --address ":9000" /data'`, vars `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` generated locally)
3. `create_service` name `Postgres`, repo `elleryfamilia/langfuse-lite-railway`, root directory `services/postgres`; `create_volume` mount `/var/lib/postgresql/data`; `set_variables`:
   `POSTGRES_USER=postgres`, `POSTGRES_DB=langfuse`, `POSTGRES_PASSWORD=<openssl rand -hex 16>`, `PGDATA=/var/lib/postgresql/data/pgdata`, `TZ=UTC`, `PGTZ=UTC`
4. `create_service` name `ClickHouse`, same repo, root directory `services/clickhouse`; `create_volume` mount `/var/lib/clickhouse`; `set_variables`: `CLICKHOUSE_DB=default`, `CLICKHOUSE_USER=clickhouse`, `CLICKHOUSE_PASSWORD=<openssl rand -hex 16>`
5. `create_service` name `Langfuse`, same repo, root directory `services/langfuse`; **`generate_domain` for it now**; `update_service` healthcheck path `/api/public/health` and healthcheck timeout 600 (if the MCP field isn't exposed, set variable `RAILWAY_HEALTHCHECK_TIMEOUT_SEC=600` — verify which mechanism Railway currently honors); then `set_variables` (reference syntax verified with `list_variables` afterward; `${{langfuse-data.*}}` names come from the bucket's Variable References panel):

```
DATABASE_URL=postgresql://${{Postgres.POSTGRES_USER}}:${{Postgres.POSTGRES_PASSWORD}}@${{Postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/${{Postgres.POSTGRES_DB}}
CLICKHOUSE_URL=http://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:9000
CLICKHOUSE_USER=${{ClickHouse.CLICKHOUSE_USER}}
CLICKHOUSE_PASSWORD=${{ClickHouse.CLICKHOUSE_PASSWORD}}
CLICKHOUSE_CLUSTER_ENABLED=false
REDIS_CONNECTION_STRING=redis://127.0.0.1:6379
NEXTAUTH_URL=https://${{RAILWAY_PUBLIC_DOMAIN}}
NEXTAUTH_SECRET=<openssl rand -hex 32>
SALT=<openssl rand -hex 32>
ENCRYPTION_KEY=<openssl rand -hex 32>   # yields 64 hex chars — required length
PORT=3000
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=${{langfuse-data.BUCKET}}
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=${{langfuse-data.ENDPOINT}}
LANGFUSE_S3_EVENT_UPLOAD_REGION=${{langfuse-data.REGION}}
LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=${{langfuse-data.ACCESS_KEY_ID}}
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${{langfuse-data.SECRET_ACCESS_KEY}}
LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/
LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=false
LANGFUSE_S3_MEDIA_UPLOAD_BUCKET=${{langfuse-data.BUCKET}}
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT=${{langfuse-data.ENDPOINT}}
LANGFUSE_S3_MEDIA_UPLOAD_REGION=${{langfuse-data.REGION}}
LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID=${{langfuse-data.ACCESS_KEY_ID}}
LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=${{langfuse-data.SECRET_ACCESS_KEY}}
LANGFUSE_S3_MEDIA_UPLOAD_PREFIX=media/
LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE=false
LANGFUSE_INIT_ORG_ID=test-org
LANGFUSE_INIT_PROJECT_ID=test-project
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-cloudtest-<openssl rand -hex 8>
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-cloudtest-<openssl rand -hex 8>
LANGFUSE_INIT_USER_EMAIL=ellery@familia.me
LANGFUSE_INIT_USER_NAME=Ellery
LANGFUSE_INIT_USER_PASSWORD=<openssl rand -hex 12>
```
(No `HOSTNAME` variable — the launcher owns the `::` binding. MinIO fallback: swap the five `${{langfuse-data.*}}` groups for `http://${{MinIO.RAILWAY_PRIVATE_DOMAIN}}:9000`, bucket `langfuse`, MinIO's root creds, `FORCE_PATH_STYLE=true`.)

- [ ] **Step 2: Deploy and verify on real infrastructure**

- Trigger deploys if not automatic; poll `list_deployments` / `environment_status` until all services are `SUCCESS`.
- `get_logs` on Langfuse: expect "postgres reachable", "clickhouse reachable", migrations, then worker start after health.
- From local shell against `https://<generated-domain>`: health 200 → ingest a trace with the INIT keys → poll `/api/public/traces/<id>` until 200 (reuse Task 1's curl commands with the domain substituted).
Expected: trace queryable — proves the Railway bucket works as Langfuse's S3.

- [ ] **Step 3: Remove INIT bootstrap variables**

Delete ALL `LANGFUSE_INIT_*` variables from the Langfuse service and redeploy. These carry real PII (your email) and must never reach the template.
Verify: `list_variables` shows no `LANGFUSE_INIT_*`.

---

### Task 10: Compose and publish the template

**Files:** none (Railway dashboard; browser)

**Interfaces:**
- Consumes: proven test project (Task 9); README overview copy (Task 4); Task 0's bucket outcome.
- Produces: published marketplace template "Langfuse Lite".

- [ ] **Step 1: Convert the project**

Railway dashboard (user drives, or claude-in-chrome with the user watching): `langfuse-lite-test` → Settings → **Generate Template from Project**. Confirm in the composer: three services sourced from the GitHub repo with root directories `services/langfuse`, `services/clickhouse`, `services/postgres` (NOT images); volumes on Postgres and ClickHouse; healthcheck + public networking (HTTP) on the app service — without a declared domain, deployers get an empty `RAILWAY_PUBLIC_DOMAIN` and broken auth callbacks. Apply Task 0's outcome for storage (bucket carried over, or MinIO service per Task 9's fallback wiring).

- [ ] **Step 2: Secret audit — deny by default**

Enumerate EVERY variable on EVERY service in the composer. Each must be one of:
1. a `${{...}}` reference or template function, or
2. an explicitly-reviewed non-secret literal (e.g., `PORT=3000`, `CLICKHOUSE_DB=default`, `TZ=UTC`).

Convert generated values: `POSTGRES_PASSWORD`, `CLICKHOUSE_PASSWORD`, `NEXTAUTH_SECRET`, `SALT` → `${{secret()}}`; `ENCRYPTION_KEY` → `${{secret(64, "abcdef0123456789")}}`. Confirm zero `LANGFUSE_INIT_*` anywhere, zero literal bucket/MinIO credentials, zero personal data. Anything unexplained blocks publish. Write the pass/fail list down before proceeding.

- [ ] **Step 3: Metadata and publish**

- Name: `Langfuse Lite` (no version — the overview's version line is bump-maintained).
- Icons: Langfuse logo (1:1, transparent) for the app; official Postgres/ClickHouse logos for theirs.
- Overview: paste README content.
- Publish under Ellery's personal workspace (honest non-affiliation, stated in the overview).

- [ ] **Step 4: Final end-to-end — deploy the published template fresh**

Deploy the published template into a brand-new project. Expected: zero variable prompts, all services green within the healthcheck window, and: create account in UI → create API key → curl one trace in → see it in the UI. This is the release gate.

- [ ] **Step 5: Teardown test resources**

Ask the user before deleting anything. Then remove `langfuse-lite-test` and the final-E2E project, keeping the published template.

---

### Task 11: Record findings and finish

**Files:**
- Modify: `docs/superpowers/specs/2026-08-07-langfuse-lite-railway-template-design.md` (Risks — final bucket answer; reconcile any drift)
- Modify: `README.md` (add the marketplace deploy link)

**Interfaces:**
- Consumes: outcomes of Tasks 9–10.
- Produces: final state; branch integration via superpowers:finishing-a-development-branch.

- [ ] **Step 1: Fresh branch from main**

The feature branch was squash-merged in Task 8 — never reuse it. Start clean:
```bash
git checkout main && git pull && git checkout -b docs/publish-outcome
```

- [ ] **Step 2: Update docs, PR, integrate**

Record the empirical bucket outcome in the spec's Risks table; add `**Deploy:** https://railway.com/deploy/<template-code>` to the top of README.
```bash
git add -A && git commit -m "docs: record template publish outcome and deploy link"
git push -u origin docs/publish-outcome
gh pr create --base main --title "docs: publish outcome" --body "Records bucket finding and adds marketplace deploy link."
gh run watch --exit-status "$(gh run list --branch docs/publish-outcome --limit 1 --json databaseId --jq '.[0].databaseId')"
gh pr merge --squash "$(gh pr list --head docs/publish-outcome --json number --jq '.[0].number')"
```
Then use superpowers:finishing-a-development-branch for any remaining cleanup.
