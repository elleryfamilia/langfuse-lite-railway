# Deploy and Host Langfuse Lite on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/langfuse-lite)

**Live on the Railway marketplace:** https://railway.com/deploy/langfuse-lite

Langfuse is an open-source LLM engineering platform: tracing, evals, prompt
management, and metrics. **Langfuse Lite** deploys it in just 3 services + a
storage bucket — about half the footprint of a full production topology —
for pre-production environments where cost matters more than high
availability. This is an unofficial community template, not affiliated with
Langfuse GmbH.

Current Langfuse version: 4.38.0

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

**This template runs Langfuse's v4-native ingestion path (`events_only` write
mode).** Instrument with Python SDK ≥4.7.0, JS SDK ≥5.4.0, or native
OpenTelemetry. Older SDKs that use the legacy batch ingestion endpoint are
rejected — the API returns a per-event "Event type not accepted" error — so
their traces never appear.

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
roughly 2 GB RAM for the app service. The ClickHouse pin is checked against
upstream automatically whenever a Langfuse release bumps; the Postgres pin
is updated manually and does not self-update. For production use Langfuse
Cloud or a full 6-service template.

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
