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
INGEST_RAW=$(curl -s -u "$PK:$SK" -H 'Content-Type: application/json' \
  -X POST http://localhost:3000/api/public/ingestion \
  -d "{\"batch\":[{\"id\":\"evt-$TRACE_ID\",\"type\":\"trace-create\",\"timestamp\":\"$NOW\",\"body\":{\"id\":\"$TRACE_ID\",\"name\":\"smoke-trace\"}}]}" \
  -w '\n%{http_code}') || fail "ingestion request failed"
INGEST_HTTP=$(echo "$INGEST_RAW" | tail -n1)
INGEST_RESPONSE=$(echo "$INGEST_RAW" | sed '$d')
echo "ingestion response (HTTP $INGEST_HTTP): $INGEST_RESPONSE"
case "$INGEST_HTTP" in
  2??) ;;
  *) fail "ingestion API returned HTTP $INGEST_HTTP: $INGEST_RESPONSE (401 means LANGFUSE_INIT_* bootstrap did not run)" ;;
esac
echo "$INGEST_RESPONSE" | python3 -c 'import json,sys; r=json.load(sys.stdin); errs=r.get("errors",[]); sys.exit(1 if errs else 0)' \
  || fail "ingestion API returned HTTP $INGEST_HTTP with per-event errors: $INGEST_RESPONSE"

echo "waiting for trace to be queryable (web -> redis -> worker -> s3 -> clickhouse)..."
ok=""
for _ in $(seq 1 90); do
  if curl -sf -u "$PK:$SK" "http://localhost:3000/api/public/traces/$TRACE_ID" >/dev/null; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || fail "trace never became queryable"

PGTZ_ACTUAL=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d langfuse -tAc "show timezone") || fail "could not query postgres timezone"
echo "$PGTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "postgres timezone is '$PGTZ_ACTUAL', not UTC"
CHTZ_ACTUAL=$("${COMPOSE[@]}" exec -T clickhouse clickhouse-client --user clickhouse --password clickhouse --query "SELECT timezone()") || fail "could not query clickhouse timezone"
echo "$CHTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "clickhouse timezone is '$CHTZ_ACTUAL', not UTC"

echo "SMOKE PASS"
