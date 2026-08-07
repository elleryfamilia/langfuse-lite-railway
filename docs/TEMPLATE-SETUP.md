# Railway template composer — exact values

> **Status: published.** The template is live at
> https://railway.com/deploy/langfuse-lite and all values below are already
> entered. Keep this document as the reference for what the template contains
> and for rebuilding it from scratch if it is ever regenerated from a project
> (regeneration strips literal values again).

The Railway template is generated from the working `langfuse-lite-test` project.
The generator **strips every literal variable value** (references like
`${{Postgres.POSTGRES_PASSWORD}}` survive; plain values do not), so each service's
variables must be re-entered once in the composer.

Use each service's **Variables tab → Raw Editor**, paste the block below, click
**Update Variables**, then click **Save** at the top right. Save persists the
draft — navigating away without saving discards everything.

Verified live on Railway 2026-08-07: a trace sent to `/api/public/otel/v1/traces`
was queryable via `/api/public/v2/observations` in 4 seconds using exactly this
configuration.

## Postgres

```
TZ="UTC"
PGTZ="UTC"
PGDATA="/var/lib/postgresql/data/pgdata"
POSTGRES_DB="langfuse"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="${{secret()}}"
```

## ClickHouse

```
CLICKHOUSE_DB="default"
CLICKHOUSE_USER="clickhouse"
CLICKHOUSE_PASSWORD="${{secret()}}"
```

## Langfuse

Replace `BUCKETNAME` with the template's bucket name as shown on the canvas.
The bucket must be **deployed** before its credentials resolve — an undeployed
bucket makes every `${{BUCKETNAME.*}}` reference silently empty.

```
PORT="3000"
DATABASE_URL="postgresql://${{Postgres.POSTGRES_USER}}:${{Postgres.POSTGRES_PASSWORD}}@${{Postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/${{Postgres.POSTGRES_DB}}"
NEXTAUTH_URL="https://${{RAILWAY_PUBLIC_DOMAIN}}"
NEXTAUTH_SECRET="${{secret()}}"
SALT="${{secret()}}"
CLICKHOUSE_URL="http://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:8123"
CLICKHOUSE_MIGRATION_URL="clickhouse://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:9000"
CLICKHOUSE_USER="${{ClickHouse.CLICKHOUSE_USER}}"
CLICKHOUSE_PASSWORD="${{ClickHouse.CLICKHOUSE_PASSWORD}}"
CLICKHOUSE_CLUSTER_ENABLED="false"
REDIS_CONNECTION_STRING="redis://127.0.0.1:6379"
LANGFUSE_S3_EVENT_UPLOAD_BUCKET="${{BUCKETNAME.BUCKET}}"
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT="${{BUCKETNAME.ENDPOINT}}"
LANGFUSE_S3_EVENT_UPLOAD_REGION="${{BUCKETNAME.REGION}}"
LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID="${{BUCKETNAME.ACCESS_KEY_ID}}"
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY="${{BUCKETNAME.SECRET_ACCESS_KEY}}"
LANGFUSE_S3_EVENT_UPLOAD_PREFIX="events/"
LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE="false"
LANGFUSE_S3_MEDIA_UPLOAD_BUCKET="${{BUCKETNAME.BUCKET}}"
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT="${{BUCKETNAME.ENDPOINT}}"
LANGFUSE_S3_MEDIA_UPLOAD_REGION="${{BUCKETNAME.REGION}}"
LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID="${{BUCKETNAME.ACCESS_KEY_ID}}"
LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY="${{BUCKETNAME.SECRET_ACCESS_KEY}}"
LANGFUSE_S3_MEDIA_UPLOAD_PREFIX="media/"
LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE="false"
```

`ENCRYPTION_KEY` must be set separately, via its own field rather than the raw
editor — its value contains double quotes, which the `KEY="value"` raw format
cannot nest:

```
${{secret(64, "abcdef0123456789")}}
```

## Service settings to confirm

- All three services: source = `elleryfamilia/langfuse-lite-railway`, branch `main`.
- Root directories: `services/postgres`, `services/clickhouse`, `services/langfuse`.
- Volumes: Postgres `/var/lib/postgresql/data`, ClickHouse `/var/lib/clickhouse`.
- Langfuse: HTTP port `3000`, healthcheck path `/api/public/health`, public
  networking on (an undeclared domain leaves `RAILWAY_PUBLIC_DOMAIN` empty and
  breaks auth callbacks).
- Raise the healthcheck timeout to 600s — first boot runs the full ClickHouse
  migration set and can exceed the 300s default.

## Before publishing

Audit every variable on every service. Each must be either a `${{...}}`
expression or a reviewed non-secret literal (`PORT`, `CLICKHOUSE_DB`, `TZ`,
prefixes, `false` flags). There must be **no** `LANGFUSE_INIT_*` variables and no
personal data — those exist only to bootstrap a test instance.

Template name: **Langfuse Lite** (no version number; the README carries the
version and the bump automation updates it).
