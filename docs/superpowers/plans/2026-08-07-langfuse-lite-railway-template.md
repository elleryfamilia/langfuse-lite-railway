# Langfuse Lite Railway Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a Railway marketplace template ("Langfuse Lite") that deploys Langfuse v4.6.0 in 3 services + 1 bucket, with CI that auto-bumps upstream releases behind a gating smoke test.

**Architecture:** A wrapper Docker image runs Langfuse web + worker + a localhost Redis in one container (worker gated on web health so migrations finish first). Template services deploy from one-line Dockerfiles in this repo (Railway update notifications only work for repo-based services). Postgres uses Railway's own postgres-ssl image; ClickHouse is single-node upstream; S3 is a Railway bucket (MinIO fallback if buckets can't ship in templates).

**Tech Stack:** Docker (Alpine base), bash, docker compose, GitHub Actions, GHCR, Railway (MCP tools + dashboard template composer).

## Global Constraints

- Never commit or push to `main` directly — all work on the existing branch `design/langfuse-lite-template`, integrated via PR.
- Repo git config already sets commit email `55049+elleryfamilia@users.noreply.github.com` (public repo; GitHub email privacy).
- Pinned versions (single sources of truth, exact values today): `ARG LANGFUSE_VERSION=4.6.0` in `image/Dockerfile`; `clickhouse/clickhouse-server:25.12` in `services/clickhouse/Dockerfile`; `ghcr.io/railwayapp-templates/postgres-ssl:17` in `services/postgres/Dockerfile`.
- Image name: `ghcr.io/elleryfamilia/langfuse-lite`. Tags mirror Docker Hub's Langfuse tags (no `v` prefix): `4.6.0`.
- No secrets in the repo, ever. Smoke-test credentials are throwaway literals that only bind to localhost stacks.
- Both upstream Langfuse images are Alpine, run as uid 1001 (`nextjs` / `expressjs`), workdir `/app`, PID1 `dumb-init` (verified 2026-08-07 via `docker inspect`).
- The user runs macOS/arm64 locally; CI (ubuntu) publishes amd64 images. Local `docker build` of `services/langfuse` will emit a platform warning — expected, ignored.

---

### Task 1: Smoke-test harness (the failing test)

**Files:**
- Create: `compose.smoke.yml`
- Create: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `scripts/smoke-test.sh` — exit 0 on pass; honors env `IMAGE_TAG` (prebuilt app image name; when unset, compose builds `./image`). Compose project uses app service name `app`, exposes web on `localhost:3000`. Smoke API keys are the literals `pk-lf-smoke-1234567890` / `sk-lf-smoke-1234567890` (Task 6's CI and Task 8's cloud verify reuse the ingest/query pattern).

- [ ] **Step 1: Write `compose.smoke.yml`**

```yaml
services:
  app:
    image: "${IMAGE_TAG:-langfuse-lite:dev}"
    build: ./image
    depends_on: [postgres, clickhouse, minio]
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
      LANGFUSE_S3_EVENT_UPLOAD_REGION: auto
      LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID: minio
      LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY: miniosecret
      LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT: http://minio:9000
      LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE: "true"
      LANGFUSE_S3_MEDIA_UPLOAD_BUCKET: langfuse
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
  clickhouse:
    image: clickhouse/clickhouse-server:25.12
    environment:
      CLICKHOUSE_DB: default
      CLICKHOUSE_USER: clickhouse
      CLICKHOUSE_PASSWORD: clickhouse
  minio:
    image: cgr.dev/chainguard/minio
    entrypoint: sh -c 'mkdir -p /data/langfuse && minio server --address ":9000" /data'
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: miniosecret
```

- [ ] **Step 2: Write `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f compose.smoke.yml)
PK=pk-lf-smoke-1234567890
SK=sk-lf-smoke-1234567890

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ -n "${IMAGE_TAG:-}" ]; then
  "${COMPOSE[@]}" up -d --no-build
else
  "${COMPOSE[@]}" up -d --build
fi

echo "waiting for app health..."
ok=""
for _ in $(seq 1 120); do
  if curl -sf http://localhost:3000/api/public/health >/dev/null; then ok=1; break; fi
  sleep 2
done
if [ -z "$ok" ]; then
  echo "FAIL: health timeout"; "${COMPOSE[@]}" logs app | tail -150; exit 1
fi

TRACE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sf -u "$PK:$SK" -H 'Content-Type: application/json' \
  -X POST http://localhost:3000/api/public/ingestion \
  -d "{\"batch\":[{\"id\":\"evt-$TRACE_ID\",\"type\":\"trace-create\",\"timestamp\":\"$NOW\",\"body\":{\"id\":\"$TRACE_ID\",\"name\":\"smoke-trace\"}}]}" >/dev/null

echo "waiting for trace to be queryable (web -> redis -> worker -> s3 -> clickhouse)..."
ok=""
for _ in $(seq 1 90); do
  if curl -sf -u "$PK:$SK" "http://localhost:3000/api/public/traces/$TRACE_ID" >/dev/null; then ok=1; break; fi
  sleep 2
done
if [ -z "$ok" ]; then
  echo "FAIL: trace never became queryable"; "${COMPOSE[@]}" logs app | tail -150; exit 1
fi

"${COMPOSE[@]}" exec -T postgres psql -U postgres -d langfuse -tAc "show timezone" | grep -qix utc \
  || { echo "FAIL: postgres not UTC"; exit 1; }
"${COMPOSE[@]}" exec -T clickhouse clickhouse-client --user clickhouse --password clickhouse \
  --query "SELECT timezone()" | grep -qi utc \
  || { echo "FAIL: clickhouse not UTC"; exit 1; }

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
- Produces: buildable image context at `image/` with `ARG LANGFUSE_VERSION=4.6.0` on line 1 of `image/Dockerfile` (Tasks 6/7 sed this exact line). Container serves HTTP on port 3000; expects the env contract listed in `compose.smoke.yml`.

- [ ] **Step 1: Write `image/launcher.sh`**

Process model: Redis starts immediately; web starts (its upstream entrypoint runs Postgres + ClickHouse migrations, then serves); worker waits for web health so it never races unfinished migrations. If any process exits, the launcher exits with its code so the platform restarts the container.

```bash
#!/bin/bash
set -uo pipefail

redis-server --port 6379 --bind 127.0.0.1 --save '' --appendonly no --dir /var/lib/redis-eph &
REDIS_PID=$!

(
  until wget -q --spider http://127.0.0.1:3000/api/public/health 2>/dev/null; do sleep 2; done
  cd /worker && exec ./worker/entrypoint.sh node worker/dist/index.js
) &
WORKER_PID=$!

(cd /app && exec ./web/entrypoint.sh node ./web/server.js --keepAliveTimeout 110000) &
WEB_PID=$!

shutdown() { kill -TERM "$REDIS_PID" "$WORKER_PID" "$WEB_PID" 2>/dev/null || true; }
trap shutdown TERM INT

wait -n "$REDIS_PID" "$WORKER_PID" "$WEB_PID"
CODE=$?
shutdown
wait
exit $CODE
```

- [ ] **Step 2: Write `image/Dockerfile`**

```dockerfile
ARG LANGFUSE_VERSION=4.6.0
FROM langfuse/langfuse-worker:${LANGFUSE_VERSION} AS worker

FROM langfuse/langfuse:${LANGFUSE_VERSION}
USER root
RUN apk add --no-cache bash redis \
    && mkdir -p /var/lib/redis-eph \
    && chown nextjs:nogroup /var/lib/redis-eph
COPY --from=worker --chown=nextjs:nogroup /app /worker
COPY --chown=nextjs:nogroup launcher.sh /launcher.sh
RUN chmod +x /launcher.sh
USER nextjs
ENV PORT=3000
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--", "/launcher.sh"]
```

Notes for the implementer: `nextjs`(uid 1001) and `nogroup` exist in the web image; `dumb-init` is the upstream PID1; web listens on `$PORT` (default 3000). The worker copy lands at `/worker` so its relative paths (`./worker/entrypoint.sh`, `worker/dist/index.js`) work with `cd /worker`.

- [ ] **Step 3: Run the smoke test**

Run: `./scripts/smoke-test.sh`
Expected: `SMOKE PASS` (first run downloads images; allow ~5 minutes). If health times out, check `docker compose -f compose.smoke.yml logs app` — the most likely failures are migration errors (bad ClickHouse URL) or the worker starting before web (must not happen given the health gate).

- [ ] **Step 4: Commit**

```bash
git add image/
git commit -m "feat: combined web+worker+redis wrapper image passing smoke test"
```

---

### Task 3: Template service Dockerfiles

**Files:**
- Create: `services/langfuse/Dockerfile`
- Create: `services/clickhouse/Dockerfile`
- Create: `services/postgres/Dockerfile`

**Interfaces:**
- Consumes: the GHCR image name/tag contract from Global Constraints (image does not exist remotely yet — local verification tags a local build with that name).
- Produces: the three root directories the Railway template's services point at (`services/langfuse`, `services/clickhouse`, `services/postgres`). Task 7's bump sed targets the `FROM` line of `services/langfuse/Dockerfile` and the tag in `services/clickhouse/Dockerfile`.

- [ ] **Step 1: Write the three one-line Dockerfiles**

`services/langfuse/Dockerfile`:
```dockerfile
FROM ghcr.io/elleryfamilia/langfuse-lite:4.6.0
```

`services/clickhouse/Dockerfile`:
```dockerfile
FROM clickhouse/clickhouse-server:25.12
```

`services/postgres/Dockerfile`:
```dockerfile
FROM ghcr.io/railwayapp-templates/postgres-ssl:17
```

- [ ] **Step 2: Verify all three build**

Run:
```bash
docker build -t langfuse-lite:dev image/
docker tag langfuse-lite:dev ghcr.io/elleryfamilia/langfuse-lite:4.6.0
docker build services/langfuse/ && docker build services/clickhouse/ && docker build services/postgres/
```
Expected: all three succeed (the langfuse one resolves the GHCR name from the local tag; clickhouse and postgres pull upstream).

- [ ] **Step 3: Commit**

```bash
git add services/
git commit -m "feat: repo-based service Dockerfiles for Railway template"
```

---

### Task 4: README / template overview

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: decisions in `docs/superpowers/specs/2026-08-07-langfuse-lite-railway-template-design.md`.
- Produces: the exact line `Current Langfuse version: 4.6.0` (Task 7's bump sed rewrites it); overview copy pasted into the Railway template at Task 9.

- [ ] **Step 1: Write `README.md`**

Follow Railway's required overview structure. Content requirements (write full prose, not placeholders):

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
container (worker waits for web so database migrations finish first; Redis
is in-memory only). Postgres runs Railway's own postgres-ssl image with a
volume; ClickHouse runs single-node with a volume; blob storage is a Railway
bucket. Upgrades ship as pull requests in this repo — merging a version bump
updates new deploys and notifies existing ones via Railway's template
update flow.

## Common Use Cases

- Tracing and debugging LLM apps during development
- Staging/preview environments that mirror production observability
- Personal projects and prototypes where a 6-service stack is overkill
- Evaluating Langfuse before committing to a production deployment

## Dependencies for Langfuse Lite Hosting

- Langfuse web + worker (upstream images, combined)
- PostgreSQL 17 (Railway postgres-ssl)
- ClickHouse 25.12 (single node)
- Redis 7 (embedded, ephemeral)
- Railway bucket (S3-compatible)

### Deployment Dependencies

- https://langfuse.com/self-hosting
- https://github.com/elleryfamilia/langfuse-lite-railway (this template's source)
- https://ghcr.io/elleryfamilia/langfuse-lite (prebuilt image)

### Implementation Details

**Not for production.** No HA, single-node ClickHouse, ephemeral Redis queue
(a redeploy can drop queued-but-unprocessed events), no backups. For
production use Langfuse Cloud or a full 6-service template.

### Why Deploy Langfuse Lite on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway
will host your infrastructure so you don't have to deal with configuration,
while allowing you to vertically and horizontally scale it.

By deploying Langfuse Lite on Railway, you get full LLM observability for
your pre-production apps at the lowest service footprint available.
```

Also append a short "Development" section documenting the two commands: `./scripts/smoke-test.sh` (full local E2E) and how the bump automation works (scheduled action opens PR; merging publishes).

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
- Create: `.gitignore` (entries: `.DS_Store`, `*.log`)

**Interfaces:**
- Consumes: all prior tasks committed on `design/langfuse-lite-template`.
- Produces: public repo `elleryfamilia/langfuse-lite-railway` with `main` as default branch containing all work so far; later tasks (CI, Railway services) depend on it existing.

- [ ] **Step 1: Create `.gitignore`, commit**

```bash
printf '.DS_Store\n*.log\n' > .gitignore
git add .gitignore && git commit -m "chore: add gitignore"
```

- [ ] **Step 2: Create the public repo and push the branch**

```bash
gh repo create elleryfamilia/langfuse-lite-railway --public --description "Langfuse Lite — minimal Langfuse deployment template for Railway (3 services + bucket)" --source . --push
git push -u origin design/langfuse-lite-template
```
Note: `--source . --push` pushes the current branch. The repo will have no `main` yet; create it from the current branch state via PR merge in the next step.

- [ ] **Step 3: Bootstrap `main`**

Rule: if `main` does not exist yet, creating it from the reviewed branch IS the initial publish (the one sanctioned direct write — there is no history to protect). Once `main` exists, all subsequent changes reach it via PR only.

```bash
git push origin design/langfuse-lite-template:refs/heads/main
gh repo edit elleryfamilia/langfuse-lite-railway --default-branch main
```
Continue working on `design/langfuse-lite-template`.

- [ ] **Step 4: Verify**

Run: `gh repo view elleryfamilia/langfuse-lite-railway --json defaultBranchRef,visibility --jq '.defaultBranchRef.name + " " + .visibility'`
Expected: `main PUBLIC`

---

### Task 6: CI — build, smoke-test, publish (`build.yml`)

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `scripts/smoke-test.sh` `IMAGE_TAG` contract (Task 1); `ARG LANGFUSE_VERSION` pin line (Task 2).
- Produces: GHCR package `ghcr.io/elleryfamilia/langfuse-lite:<version>` published from same-repo branches/PRs; `main` verifies the tag exists. Triggers on `push` to `main` and `bump/**` (workflow-created PRs don't trigger `pull_request` workflows when opened with `GITHUB_TOKEN` — branch-push triggering sidesteps that GitHub limitation).

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: build
on:
  pull_request:
  push:
    branches: [main, "bump/**", "design/**", "feat/**"]

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/elleryfamilia/langfuse-lite

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: ver
        name: Read pinned Langfuse version
        run: echo "version=$(sed -n 's/^ARG LANGFUSE_VERSION=//p' image/Dockerfile)" >> "$GITHUB_OUTPUT"

      - name: Build wrapper image
        run: docker build -t "$IMAGE:${{ steps.ver.outputs.version }}" image/

      - name: Smoke test the built image
        run: IMAGE_TAG="$IMAGE:${{ steps.ver.outputs.version }}" ./scripts/smoke-test.sh

      - name: Log in to GHCR
        if: github.event_name == 'push'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Publish exact-version tag (non-main branches)
        if: github.event_name == 'push' && github.ref != 'refs/heads/main'
        run: docker push "$IMAGE:${{ steps.ver.outputs.version }}"

      - name: Verify tag exists for main's pin
        if: github.ref == 'refs/heads/main'
        run: docker manifest inspect "$IMAGE:${{ steps.ver.outputs.version }}" || docker push "$IMAGE:${{ steps.ver.outputs.version }}"
```

- [ ] **Step 2: Push and watch the workflow run**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build, smoke-test, and publish wrapper image"
git push
gh run watch --exit-status "$(gh run list --branch design/langfuse-lite-template --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: green run — build, smoke test (real end-to-end in CI), and GHCR publish of `4.6.0` (branch push → publish step runs).

- [ ] **Step 3: Verify the published image is publicly pullable**

Run:
```bash
gh api "user/packages/container/langfuse-lite" --jq .visibility
```
If `private` (GHCR default for first publish): make it public at https://github.com/users/elleryfamilia/packages/container/langfuse-lite/settings (Danger Zone → Change visibility → Public), then re-run the command.
Expected: `public`, and `docker manifest inspect ghcr.io/elleryfamilia/langfuse-lite:4.6.0` succeeds from a logged-out shell (`docker logout ghcr.io` first).

---

### Task 7: CI — scheduled version bump (`bump.yml`)

**Files:**
- Create: `.github/workflows/bump.yml`

**Interfaces:**
- Consumes: pin lines from Tasks 2/3/4 (`ARG LANGFUSE_VERSION=` in `image/Dockerfile`; `FROM ghcr.io/elleryfamilia/langfuse-lite:` in `services/langfuse/Dockerfile`; `clickhouse-server:` tag in `services/clickhouse/Dockerfile`; `Current Langfuse version:` in `README.md`).
- Produces: branches named `bump/langfuse-<version>` + PRs; `build.yml`'s `bump/**` push trigger builds and publishes them.

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

jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: vers
        name: Compare pinned vs latest upstream
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          LATEST=$(gh api repos/langfuse/langfuse/releases/latest --jq .tag_name | sed 's/^v//')
          CURRENT=$(sed -n 's/^ARG LANGFUSE_VERSION=//p' image/Dockerfile)
          echo "latest=$LATEST" >> "$GITHUB_OUTPUT"
          echo "current=$CURRENT" >> "$GITHUB_OUTPUT"

      - name: Open bump PR
        if: steps.vers.outputs.latest != steps.vers.outputs.current
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          NEW="${{ steps.vers.outputs.latest }}"
          git checkout -b "bump/langfuse-$NEW"

          sed -i "s/^ARG LANGFUSE_VERSION=.*/ARG LANGFUSE_VERSION=$NEW/" image/Dockerfile
          sed -i "s#^FROM ghcr.io/elleryfamilia/langfuse-lite:.*#FROM ghcr.io/elleryfamilia/langfuse-lite:$NEW#" services/langfuse/Dockerfile
          sed -i "s/^Current Langfuse version: .*/Current Langfuse version: $NEW/" README.md

          # Track upstream's ClickHouse pin if it moved
          CH=$(curl -sf "https://raw.githubusercontent.com/langfuse/langfuse/v$NEW/docker-compose.yml" \
            | sed -n 's/.*clickhouse-server:\([0-9][0-9.]*\).*/\1/p' | head -1)
          if [ -n "$CH" ]; then
            sed -i "s#^FROM clickhouse/clickhouse-server:.*#FROM clickhouse/clickhouse-server:$CH#" services/clickhouse/Dockerfile
          fi

          git config user.name "langfuse-lite-bot"
          git config user.email "55049+elleryfamilia@users.noreply.github.com"
          git commit -am "feat: bump Langfuse to $NEW"
          git push -u origin "bump/langfuse-$NEW"
          gh pr create --base main \
            --title "feat: bump Langfuse to $NEW" \
            --body "Automated upstream bump. The branch push triggers build.yml (build + smoke test + GHCR publish of \`$NEW\`). Merge only when green."
```

- [ ] **Step 2: Push, then dry-run via workflow_dispatch**

```bash
git add .github/workflows/bump.yml
git commit -m "ci: scheduled upstream release bump PRs"
git push
gh workflow run bump --ref design/langfuse-lite-template
sleep 20
gh run watch --exit-status "$(gh run list --workflow bump --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: green run that does NOT open a PR (pinned version already equals latest). If upstream released since 2026-08-07, a `bump/langfuse-*` PR appears instead — verify its build run goes green, then close it or merge it per its diff.

---

### Task 8: Live test project on Railway (answers the bucket question for real infra)

**Files:** none (Railway MCP operations; findings recorded in Task 10's notes)

**Interfaces:**
- Consumes: public repo with `main` containing everything (merge the working branch via PR first — see Step 1); GHCR image public (Task 6).
- Produces: a working Railway project named `langfuse-lite-test` proving the 3-service + bucket topology on real infrastructure; kept alive as the source for template conversion in Task 9.

- [ ] **Step 1: Merge working branch to main via PR**

```bash
gh pr create --base main --head design/langfuse-lite-template --title "feat: Langfuse Lite v1" --body "Wrapper image, service Dockerfiles, CI, README, design docs. Smoke test green locally and in CI."
gh pr merge --squash --auto "$(gh pr list --head design/langfuse-lite-template --json number --jq '.[0].number')"
```
Expected: PR merges once build.yml is green. Template services deploy from `main` from here on.

- [ ] **Step 2: Create project, bucket, and the three services (Railway MCP)**

Using Railway MCP tools in this order (values verbatim):
1. `create_project` name `langfuse-lite-test`
2. `create_bucket` in that project/environment, name `langfuse-data`
3. `create_service` name `Postgres`, source repo `elleryfamilia/langfuse-lite-railway`, root directory `services/postgres`; `create_volume` mount path `/var/lib/postgresql/data`; `set_variables`: `POSTGRES_USER=postgres`, `POSTGRES_DB=langfuse`, `POSTGRES_PASSWORD=<generate locally: openssl rand -hex 16>`, `PGDATA=/var/lib/postgresql/data/pgdata`
4. `create_service` name `ClickHouse`, same repo, root directory `services/clickhouse`; `create_volume` mount path `/var/lib/clickhouse`; `set_variables`: `CLICKHOUSE_DB=default`, `CLICKHOUSE_USER=clickhouse`, `CLICKHOUSE_PASSWORD=<generate locally: openssl rand -hex 16>`
5. `create_service` name `Langfuse`, same repo, root directory `services/langfuse`; `set_variables` (use `add_reference_variable` where the value references another service/bucket):

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
HOSTNAME=::
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
6. `generate_domain` for the Langfuse service; set healthcheck path `/api/public/health` via `update_service`.

Adjust exact reference syntax to what the MCP tools accept (verify with `list_variables` after setting; the `${{Bucket.*}}` names come from the bucket's Variable References panel).

- [ ] **Step 3: Deploy and verify on real infrastructure**

- Trigger deploys (`deploy` tool per service if not automatic), then poll `list_deployments` / `environment_status` until all three are `SUCCESS`.
- `get_logs` on Langfuse: confirm migrations ran, worker started after health, no S3 errors.
- From local shell, run the cloud equivalent of the smoke assertions against `https://<generated-domain>`: health 200 → ingest a trace with the INIT keys → poll `/api/public/traces/<id>` until 200. Reuse the curl commands from Task 1 with the domain substituted.
Expected: trace queryable — proves the Railway bucket works as Langfuse's S3 (the design's main empirical question for runtime).

- [ ] **Step 4: Remove INIT bootstrap variables**

Delete all `LANGFUSE_INIT_*` variables from the Langfuse service (`set_variables` with removal or dashboard) and redeploy. These must NOT leak into the template.
Verify: `list_variables` shows no `LANGFUSE_INIT_*`.

---

### Task 9: Compose and publish the template

**Files:** none (Railway dashboard; browser)

**Interfaces:**
- Consumes: proven test project (Task 8); README overview copy (Task 4).
- Produces: published marketplace template "Langfuse Lite".

- [ ] **Step 1: Convert or compose**

In the Railway dashboard (user drives, or claude-in-chrome with the user watching): from `langfuse-lite-test` project → Settings → **Generate Template from Project**. In the composer, verify what carried over — **this empirically answers whether buckets can ship in templates.**
- If the bucket carried into the composer: proceed.
- If NOT (fallback, per approved design): remove bucket references; add a 4th service `MinIO` — image `cgr.dev/chainguard/minio`, volume at `/data`, start command `sh -c 'mkdir -p /data/langfuse && minio server --address ":9000" /data'`, variables `MINIO_ROOT_USER=${{secret()}}`, `MINIO_ROOT_PASSWORD=${{secret()}}`; rewire the app's `LANGFUSE_S3_*` variables to `http://${{MinIO.RAILWAY_PRIVATE_DOMAIN}}:9000`, bucket `langfuse`, `FORCE_PATH_STYLE=true`, keys referencing MinIO's variables.

- [ ] **Step 2: Replace concrete secrets with template variable functions**

In the composer, for every variable that came over with a concrete test value:
- `POSTGRES_PASSWORD`, `CLICKHOUSE_PASSWORD`, `NEXTAUTH_SECRET`, `SALT` → `${{secret()}}`
- `ENCRYPTION_KEY` → `${{secret(64, "abcdef0123456789")}}`
- Confirm NO `LANGFUSE_INIT_*` variables exist anywhere.
- Confirm reference variables (`DATABASE_URL`, `CLICKHOUSE_*`, `LANGFUSE_S3_*`, `NEXTAUTH_URL`) survived conversion; re-add per Task 8 Step 2 if not.
- Service sources must show the GitHub repo + root directories (not images); healthcheck `/api/public/health` on the app; volumes present on Postgres (`/var/lib/postgresql/data`) and ClickHouse (`/var/lib/clickhouse`).

- [ ] **Step 3: Metadata and publish**

- Template name: `Langfuse Lite` (no version in the name — the README/overview carries the version line).
- Icons: Langfuse logo for the app service (1:1, transparent), official Postgres/ClickHouse logos for theirs.
- Overview: paste README content (already in Railway's required format).
- Publish to marketplace (workspace: Ellery's personal — honest non-affiliation, stated in overview).

- [ ] **Step 4: Final end-to-end — deploy the published template fresh**

Deploy the published template into a brand-new project (one click, zero variable entry expected). Wait for all services green. Create an account in the UI, create a project, create an API key, send one trace (curl as in Task 1), see it in the UI.
Expected: complete cold-start success with no manual variables. This is the release gate.

- [ ] **Step 5: Teardown test resources**

Ask the user before deleting anything. Then remove `langfuse-lite-test` and the final-E2E project (dashboard or MCP `remove_service`/project deletion), keeping the published template.

---

### Task 10: Record findings and finish the branch

**Files:**
- Modify: `docs/superpowers/specs/2026-08-07-langfuse-lite-railway-template-design.md` (Risks section — record the empirical bucket answer)
- Modify: `README.md` (add the published template's marketplace URL badge/link at the top)

**Interfaces:**
- Consumes: outcomes of Tasks 8–9.
- Produces: final state; branch integration via superpowers:finishing-a-development-branch.

- [ ] **Step 1: Update spec Risks + README with the bucket outcome and template URL**

Edit the spec's risk table row "Buckets can't be included in published templates" to state what was actually observed. Add to README top: `**Deploy:** https://railway.com/deploy/<template-code>`.

- [ ] **Step 2: Commit and integrate**

```bash
git add -A && git commit -m "docs: record template publish outcome and deploy link"
git push
gh pr create --base main --title "docs: publish outcome" --body "Records bucket finding and adds marketplace link."
```
Then use superpowers:finishing-a-development-branch for final integration.
