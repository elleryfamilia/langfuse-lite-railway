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
2. **Image distribution:** the real wrapper image is prebuilt and pushed to
   GHCR (`ghcr.io/elleryfamilia/langfuse-lite`), pinned to exact upstream
   Langfuse versions. Template services, however, deploy **from the GitHub
   repo** via one-line Dockerfiles (`FROM ghcr.io/…:vX.Y.Z`) — because
   Railway's template-update notifications only work for repo-based services;
   image-based template services can never be updated without hand-editing
   the template (docs: /templates/updates).
3. **Upgrade policy:** scheduled CI checks upstream releases and opens bump
   PRs; PR CI builds, smoke-tests, and pushes the exact-version GHCR tag
   *before* merge (avoids a merge-then-image-missing race). Merging to `main`
   flips the repo pin, which makes new deploys use the new version and
   triggers Railway's "update available" notification for existing
   deployers. No unreviewed auto-publishing; no manual template edits.
4. **S3 layer:** Railway bucket first; if the template composer cannot include
   buckets, ship MinIO as a 4th service and swap to a bucket when supported.
5. **Naming:** the template is named **"Langfuse Lite"** with no version in
   the name. Version-pegged template names (common on the marketplace) go
   stale because nothing updates them. Current version is stated in the
   README/overview, which the bump PR also updates.

## Runtime architecture

### Service 1: `Langfuse` (app)

- Image: `ghcr.io/elleryfamilia/langfuse-lite:<upstream-version>`. Initial pin:
  **v4.6.0** (latest upstream release as of 2026-08-07). The template service
  builds from `services/langfuse/` in this repo, whose Dockerfile is a single
  `FROM` of that image (see Repo layout / CI for why).
- One container, three processes under a lightweight supervisor:
  - **Langfuse web** — upstream `langfuse/langfuse` base. Serves UI + API on
    port 3000. Public Railway domain attached. Healthcheck:
    `/api/public/health`. Runs DB migrations on boot (upstream behavior).
  - **Langfuse worker** — upstream `langfuse/langfuse-worker`, copied into the
    image via multi-stage build. Async event processing.
  - **Redis** — Redis 7 (upstream compose parity), installed in-image, bound
    to localhost only.
- Supervisor: a bash launcher script under the image's existing `dumb-init`
  PID1: start Redis, start web (upstream entrypoint runs migrations then
  serves), start the worker gated on web health (`wget --spider` loop against
  `/api/public/health` so it never races unfinished migrations), then
  `wait -n` — when any process exits, kill the rest and exit with its code so
  Railway restarts the container. supervisord was considered and rejected: it
  does not exit when a child dies without an event-listener workaround, which
  is more machinery than the bash script it would replace. Requirements
  either way: forward SIGTERM to children; container death on any process
  death.
- No volume. Redis queue/cache is deliberately ephemeral; a redeploy may drop
  queued-but-unprocessed events. Documented as an accepted pre-prod trade-off.
- The worker runs on internal port 3030 (it binds `env.PORT`, so the launcher
  must export `PORT=3030` in its subshell or it collides with web on 3000);
  web binds `::` (IPv6 dual-stack) via a launcher export, which Railway's
  IPv6-only private networking requires.
- Railway templates cannot pin service resources; the README documents a
  ~2 GB RAM guideline for the app service instead.

### Service 2: `Postgres`

- Base: `ghcr.io/railwayapp-templates/postgres-ssl:17` — the image Railway's
  own "Add Postgres" deploys. Gets SSL, correct volume/`PGDATA`-subdirectory
  handling (plain `postgres:17` can fail to init on a Railway volume because
  the mount point isn't empty), and Railway-conventional behavior for free.
- Volume at `/var/lib/postgresql/data` with `PGDATA` pointing at its `pgdata`
  subdirectory (postgres-ssl convention). Must run UTC (default; verified in
  smoke test since Langfuse requires UTC).
- Standard Railway variable set replicated in the template: `POSTGRES_USER`,
  `POSTGRES_PASSWORD` (via `${{secret()}}`), `POSTGRES_DB`, `PGHOST`/`PGPORT`
  on the private domain, and `DATABASE_URL` for other services to reference.

### Service 3: `ClickHouse`

- Upstream `clickhouse/clickhouse-server:25.12` (the version Langfuse's own
  docker-compose pins for v4.6.0; bump PRs re-check this pin).
- Single node, `CLICKHOUSE_CLUSTER_ENABLED=false` on the app — no
  Keeper/ZooKeeper.
- Volume at `/var/lib/clickhouse`. User/password via `${{secret()}}`.

### Storage: Railway Bucket (confirmed supported in templates, 2026-08-07)

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

**Zero required user input:** every variable is either generated
(`${{secret()}}`) or wired via reference variables, so deploying is a single
click. The first human step is account signup in the Langfuse UI. Optional
extras (e.g., SMTP for email invites) may be added later as clearly-labeled
optional variables, never required ones.

### Explicit non-goals

- High availability, horizontal scaling, ClickHouse clustering, Redis
  persistence, backups. The template README states plainly: pre-production
  use; for production, use a full 6-service template or Langfuse Cloud.

## Repo layout

```
langfuse-lite-railway/
├── image/
│   ├── Dockerfile          # the real image: worker + redis + launcher into web image
│   └── launcher.sh         # bash launcher: readiness waits, redis, web, health-gated worker
├── services/               # what the template's services actually deploy
│   ├── langfuse/Dockerfile   # FROM ghcr.io/elleryfamilia/langfuse-lite:4.6.0
│   ├── clickhouse/Dockerfile # FROM clickhouse/clickhouse-server:25.12
│   └── postgres/Dockerfile   # FROM ghcr.io/railwayapp-templates/postgres-ssl:17
├── compose.smoke.yml       # local/CI stack: app image, postgres, clickhouse, minio
├── scripts/smoke-test.sh   # end-to-end assertions (see Validation)
├── .github/workflows/
│   ├── build.yml           # PR: build image, smoke test, push exact GHCR tag
│   └── bump.yml            # scheduled upstream release check → bump PR
├── README.md               # template overview in Railway's required format
└── docs/superpowers/specs/ # this document
```

Each template service points at this repo with a root directory under
`services/` (Railway's documented monorepo pattern), so **all three services**
are repo-based and receive update notifications — including future ClickHouse
or Postgres pin bumps, not just Langfuse releases. Deploy-time builds are
trivial (each Dockerfile is a `FROM` line; the build is effectively an image
pull).

Single source of truth for the pinned version: `ARG LANGFUSE_VERSION` in
`image/Dockerfile`; the bump PR keeps `services/langfuse/Dockerfile` in sync.
GHCR tags mirror upstream **Docker Hub** tags exactly (`4.6.0`, no `v`
prefix — upstream GitHub releases use `v4.6.0` but their image tags do not).

## CI

- **build.yml** — on PR: build the wrapper image, run the smoke test, and (for
  same-repo branches) push the exact-version tag to GHCR so it exists before
  the merge that references it. On main: verify the referenced tag exists.
- **bump.yml** — scheduled (daily): compare `LANGFUSE_VERSION` against the
  latest upstream GitHub release; if newer, edit both Dockerfile pins (and the
  ClickHouse pin if upstream's compose moved it), update the version line in
  README, open a PR. The PR runs build.yml, so a failing bump never ships.
- GHCR auth via the repo's built-in `GITHUB_TOKEN`; no extra secrets.
- Merge to `main` is the single publishing action: new template deploys build
  from main immediately, and existing deployers get Railway's opt-in "update
  available" notification.

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
  the GitHub repo (root directories `services/langfuse`, `services/clickhouse`,
  `services/postgres`), volumes on Postgres/ClickHouse, env wiring per the
  table above, bucket if supported (this is where the bucket question gets
  answered empirically; MinIO fallback otherwise).
- Name: **Langfuse Lite**. Proper 1:1 icons. Overview follows Railway's
  required H1/H2 structure ("Deploy and Host Langfuse Lite on Railway", use
  cases, dependencies, why Railway).
- Publish to marketplace under Ellery's workspace (not Langfuse branding —
  Railway requires honest affiliation; the template name and overview must not
  imply official Langfuse endorsement).
- No post-merge template maintenance: repo-based services make merges to
  `main` the update mechanism (see CI section). The composer is only touched
  for structural changes (new services, env contract changes).

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
| ~~Buckets can't be included in published templates~~ **RESOLVED 2026-08-07: they can.** | Verified empirically in the template composer: `Add New → Bucket` adds a "Railway Provided" bucket node needing no config, whose Credentials tab exposes Endpoint URL, Region, Bucket Name, Access Key ID, and Secret Access Key — each with a "Copy Reference" button and each "Populated after deploy", so every deployer gets their own bucket and credentials with no literal secrets in the template. MinIO fallback not needed. |
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

## Outcome (2026-08-07)

Built, tested, and verified end-to-end on live Railway infrastructure. What the
implementation proved or corrected about this design:

- **The core bet works.** One container running Langfuse web + worker + a
  localhost Redis deploys and serves correctly. On Railway, a trace sent to the
  OTLP endpoint was queryable 4 seconds later, having traversed
  web -> redis -> worker -> Railway bucket -> ClickHouse.
- **Buckets are supported in templates**, and Railway buckets work as Langfuse's
  S3 backend. The MinIO fallback was never needed.
- **A bucket must be deployed before its credentials exist.** Referencing an
  undeployed bucket yields empty strings, not an error. The
  `${{<bucket>.BUCKET}}` reference syntax itself is correct.
- **Bucket endpoint is `https://t3.storageapi.dev`, region `iad`** — not the
  `storage.railway.app` the Railway docs describe.
- **Ingestion mode was a real product decision** (owner ruling): the template
  ships Langfuse v4's upstream default `events_only`, so users need Python SDK
  >= 4.7.0 / JS >= 5.4.0 or native OpenTelemetry. The legacy batch ingestion
  endpoint rejects older SDKs with an explicit per-event error.
- **`GET /api/public/traces/<id>` is unavailable in events_only mode**; reads go
  through `GET /api/public/v2/observations`.
- **The ClickHouse threat model in this spec was wrong.** The official entrypoint
  removes the passwordless `default` user outright when `CLICKHOUSE_USER` is set;
  the lockdown file is defense-in-depth and must merge first (`00-` prefix) or
  ClickHouse crash-loops.
- **The template composer strips literal variable values** while preserving
  `${{...}}` references, so composing a template is not purely mechanical — see
  `docs/TEMPLATE-SETUP.md`.
