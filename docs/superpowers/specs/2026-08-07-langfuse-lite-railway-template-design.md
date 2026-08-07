# Langfuse Lite — Railway Template Design

**Date:** 2026-08-07
**Status:** Approved pending user review
**Repo:** `langfuse-lite-railway` (public, GitHub: elleryfamilia)

## Objective

Publish a Railway marketplace template named **"Langfuse Lite"** that deploys a
fully functional Langfuse (current v4 line) in as few Railway services as
possible. Target audience: pre-production environments (dev, staging, personal
projects) where cost matters more than high availability.

## Context

- A full Langfuse v3/v4 self-host needs 6 components, all mandatory: web app,
  worker, Postgres, ClickHouse, Redis, and S3-compatible blob storage.
- Existing Railway marketplace templates (~10 of them) all deploy the full
  6-service topology. None position themselves as a minimal/cheap option —
  "Langfuse Lite" fills that gap.
- Railway now offers native S3-compatible **buckets** ($0.015/GB-month, free
  egress and API ops) that can replace a MinIO service. Whether a bucket can be
  included in a *published template* is undocumented — treated as an open risk
  with a decided fallback (see Risks).
- Railway template facts verified against docs: services come from GitHub repos
  or Docker images; volumes attach per service; `${{secret()}}` template
  variable functions generate per-deploy secrets; reference variables wire
  credentials between services; templates publish to the marketplace and
  qualify for kickbacks (up to 25% for open source).

## Decisions made during brainstorming

1. **Service count:** ~3 services using upstream images with a thin wrapper —
   not a 1-container all-in-one (too much image maintenance), not 2 services
   (combined data container has the same maintenance problem).
2. **Image distribution:** prebuilt wrapper image pushed to GHCR
   (`ghcr.io/elleryfamilia/langfuse-lite`), pinned to exact upstream Langfuse
   versions. Not built-from-repo at deploy time.
3. **Upgrade policy:** scheduled CI checks upstream releases and opens bump
   PRs; merging builds, smoke-tests, and publishes the new tag. No unreviewed
   auto-publishing.
4. **S3 layer:** Railway bucket first; if the template composer cannot include
   buckets, ship MinIO as a 4th service and swap to a bucket when supported.

## Runtime architecture

### Service 1: `Langfuse` (app)

- Image: `ghcr.io/elleryfamilia/langfuse-lite:<upstream-version>`. Initial pin:
  **v4.6.0** (latest upstream release as of 2026-08-07).
- One container, three processes under a lightweight supervisor:
  - **Langfuse web** — upstream `langfuse/langfuse` base. Serves UI + API on
    port 3000. Public Railway domain attached. Healthcheck:
    `/api/public/health`. Runs DB migrations on boot (upstream behavior).
  - **Langfuse worker** — upstream `langfuse/langfuse-worker`, copied into the
    image via multi-stage build. Async event processing.
  - **Redis** — Redis 7 (upstream compose parity), installed in-image, bound
    to localhost only.
- Supervisor: decision rule — if the upstream base image's package manager
  provides `supervisord`, use it (it handles signal forwarding and
  exit-on-child-death declaratively); otherwise a shell entrypoint under
  `tini` that starts all three processes and exits nonzero when any child
  exits. Either way the requirements are: forward SIGTERM to children, and
  container death on any process death so Railway restarts it.
- No volume. Redis queue/cache is deliberately ephemeral; a redeploy may drop
  queued-but-unprocessed events. Documented as an accepted pre-prod trade-off.
- Default resources sized for ~1.5–2 GB RAM.

### Service 2: `Postgres`

- Upstream `postgres:17` (matches upstream compose default).
- Volume at the Postgres data dir. Must run UTC (Postgres default; verified in
  smoke test since Langfuse requires UTC).
- `POSTGRES_PASSWORD` via `${{secret()}}`.

### Service 3: `ClickHouse`

- Upstream `clickhouse/clickhouse-server:25.12` (the version Langfuse's own
  docker-compose pins for v4.6.0; bump PRs re-check this pin).
- Single node, `CLICKHOUSE_CLUSTER_ENABLED=false` on the app — no
  Keeper/ZooKeeper.
- Volume at `/var/lib/clickhouse`. User/password via `${{secret()}}`.

### Storage: Railway Bucket (or MinIO fallback)

- Bucket credentials (`BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`,
  `ENDPOINT`, `REGION`) wired to the app via reference variables.
- Railway buckets use virtual-hosted-style URLs → path-style stays **off** on
  Railway; the local smoke stack uses MinIO with path-style **on**.
- Fallback: MinIO service + volume, same env contract, path-style on.

### App environment (wired in the template)

| Variable | Source |
|---|---|
| `DATABASE_URL` | reference → Postgres private domain + generated password |
| `CLICKHOUSE_URL` | `http://<clickhouse>.railway.internal:8123` |
| `CLICKHOUSE_MIGRATION_URL` | `clickhouse://<clickhouse>.railway.internal:9000` |
| `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | reference → ClickHouse service |
| `CLICKHOUSE_CLUSTER_ENABLED` | `false` |
| `REDIS_CONNECTION_STRING` | `redis://127.0.0.1:6379` (in-container) |
| `NEXTAUTH_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` |
| `NEXTAUTH_SECRET`, `SALT` | `${{secret()}}` |
| `ENCRYPTION_KEY` | `${{secret(64, "abcdef0123456789")}}` (64 hex chars) |
| `LANGFUSE_S3_EVENT_UPLOAD_*` | reference → bucket (or MinIO) credentials |
| `LANGFUSE_S3_MEDIA_UPLOAD_*` | same bucket, media prefix |

All service-to-service traffic uses Railway private networking. No default
credentials anywhere; everything generated per-deploy.

### Explicit non-goals

- High availability, horizontal scaling, ClickHouse clustering, Redis
  persistence, backups. The template README states plainly: pre-production
  use; for production, use a full 6-service template or Langfuse Cloud.

## Repo layout

```
langfuse-lite-railway/
├── Dockerfile              # multi-stage: worker + redis + supervisor into web image
├── supervisor/             # supervisor config + entrypoint script
├── compose.smoke.yml       # local/CI stack: app image, postgres, clickhouse, minio
├── scripts/smoke-test.sh   # end-to-end assertions (see Validation)
├── .github/workflows/
│   ├── build.yml           # PR: build + smoke test; main/tag: push to GHCR
│   └── bump.yml            # scheduled upstream release check → bump PR
├── README.md               # template overview in Railway's required format
└── docs/superpowers/specs/ # this document
```

Single source of truth for the pinned version: `ARG LANGFUSE_VERSION` in the
Dockerfile. Image tags mirror upstream tags exactly.

## CI

- **build.yml** — on PR: build the wrapper image, run the smoke test. On merge
  to main / version tag: additionally push to GHCR (public package).
- **bump.yml** — scheduled (daily): compare `LANGFUSE_VERSION` against the
  latest upstream GitHub release; if newer, edit the pin and open a PR. The PR
  runs build.yml, so a failing bump never publishes.
- GHCR auth via the repo's built-in `GITHUB_TOKEN`; no extra secrets.

## Validation

`compose.smoke.yml` recreates the deployed topology locally (MinIO standing in
for the bucket). `scripts/smoke-test.sh` asserts, in order:

1. App container reports healthy on `/api/public/health` within a timeout.
2. Bootstrap org/project/API key exist via `LANGFUSE_INIT_*` env vars.
3. POST a trace to the public ingestion API succeeds.
4. The trace becomes queryable via the public API within a timeout — proving
   web → Redis → worker → S3 → ClickHouse all function.
5. Postgres and ClickHouse containers report UTC.

Runs on every PR including automated bump PRs. This is the automated harness
for the project; template-composer publishing is the one manual step.

## Publishing

- Compose the template in Railway's dashboard template editor: 3 services from
  Docker images, volumes on Postgres/ClickHouse, env wiring per the table
  above, bucket if supported (this is where the bucket question gets answered
  empirically; MinIO fallback otherwise).
- Name: **Langfuse Lite**. Proper 1:1 icons. Overview follows Railway's
  required H1/H2 structure ("Deploy and Host Langfuse Lite on Railway", use
  cases, dependencies, why Railway).
- Publish to marketplace under Ellery's workspace (not Langfuse branding —
  Railway requires honest affiliation; the template name and overview must not
  imply official Langfuse endorsement).
- Template updates after a bump merge: update the image tag in the template
  composer (manual, ~1 minute; noted in the bump PR checklist).

## Assumptions

- `langfuse/langfuse` and `langfuse/langfuse-worker` images share a compatible
  base OS so the multi-stage copy works (checked at implementation; CI catches
  regressions on every bump).
- Langfuse web and worker tolerate sharing one Redis at localhost (this is the
  standard docker-compose topology, just co-located).
- Railway buckets' virtual-hosted S3 URLs work with Langfuse's S3 client with
  path-style off (AWS SDK default behavior).

## Risks

| Risk | Mitigation |
|---|---|
| Buckets can't be included in published templates | Decided fallback: MinIO 4th service, same env contract; swap later |
| Upstream image restructure breaks the wrapper | CI smoke test on every bump PR; failed bump never publishes |
| Combined container OOMs on default resources | Size defaults ~2 GB; document minimums in README |
| Queue loss on redeploy (ephemeral Redis) | Documented, accepted for pre-prod; events already in S3 are re-processable |
| Marketplace name collision / trademark | "Langfuse Lite" + clear unofficial-community-template wording in overview |

## Rollback

- Template: Railway templates can be unpublished at any time; existing
  deployments keep running.
- Image: previous GHCR tags remain; a bad release is rolled back by repointing
  the template to the prior tag.
- Repo: standard git revert of the bump PR.

## First implementation step

Write the `Dockerfile` + supervisor config and get the combined
web+worker+Redis container running locally against `compose.smoke.yml` — this
de-risks the wrapper-image assumption before any CI or template work.
