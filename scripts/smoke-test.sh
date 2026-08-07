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

# Langfuse v4 defaults to LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only, which rejects the
# legacy batch ingestion endpoint's trace-create event (score/log only). Ingest via the
# v4-native OTLP endpoint instead. x-langfuse-ingestion-version: 4 is required for real-time
# processing -- without it events route through a ~10min dual-write staging path that blows
# this script's polling budget. OTLP/JSON trace/span ids are lowercase hex (32/16 chars), not
# base64, per the OTLP spec's JSON encoding.
TRACE_ID=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
SPAN_ID=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
START_NS=$(python3 -c 'import time; print(time.time_ns())')
END_NS=$(python3 -c 'import time; print(time.time_ns() + 1_000_000)')
OTLP_BODY=$(python3 -c "
import json
print(json.dumps({
  'resourceSpans': [{
    'resource': {'attributes': []},
    'scopeSpans': [{
      'scope': {'name': 'smoke-test', 'version': '1.0.0'},
      'spans': [{
        'traceId': '$TRACE_ID',
        'spanId': '$SPAN_ID',
        'name': 'smoke-trace',
        'kind': 1,
        'startTimeUnixNano': '$START_NS',
        'endTimeUnixNano': '$END_NS',
        'attributes': [],
      }],
    }],
  }],
}))
")

INGEST_RAW=$(curl -s -u "$PK:$SK" -H 'Content-Type: application/json' -H 'x-langfuse-ingestion-version: 4' \
  -X POST http://localhost:3000/api/public/otel/v1/traces \
  -d "$OTLP_BODY" \
  -w '\n%{http_code}') || fail "ingestion request failed"
INGEST_HTTP=$(echo "$INGEST_RAW" | tail -n1)
INGEST_RESPONSE=$(echo "$INGEST_RAW" | sed '$d')
echo "ingestion response (HTTP $INGEST_HTTP): $INGEST_RESPONSE"
case "$INGEST_HTTP" in
  2??) ;;
  *) fail "ingestion API returned HTTP $INGEST_HTTP: $INGEST_RESPONSE (401 means LANGFUSE_INIT_* bootstrap did not run)" ;;
esac
# The OTLP endpoint doesn't validate span contents synchronously -- it 200s with body "{}" for
# both an empty/unrecognized payload and a well-formed one, the only difference being whether a
# job actually got queued. Treat "no job queued" as a fail-fast rejection instead of silently
# polling and timing out with no clue why.
echo "$INGEST_RESPONSE" | python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("queueQualifiedName") else 1)' \
  || fail "ingestion API returned HTTP $INGEST_HTTP but queued no job (payload not recognized): $INGEST_RESPONSE"

echo "waiting for trace to be queryable (web -> redis -> worker -> s3 -> clickhouse)..."
# GET /api/public/traces/<id> returns 404 in v4 events_only mode -- the app's own response
# points callers at this v2/observations time-range endpoint instead. It's a list query, not a
# direct id lookup, so match our generated traceId inside data[].
FROM=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
TO=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
ok=""
for _ in $(seq 1 90); do
  RESP=$(curl -sf -u "$PK:$SK" "http://localhost:3000/api/public/v2/observations?fromStartTime=$FROM&toStartTime=$TO") || { sleep 2; continue; }
  if echo "$RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); sys.exit(0 if any(o.get('traceId')=='$TRACE_ID' for o in r.get('data',[])) else 1)"; then
    ok=1
    break
  fi
  sleep 2
done
[ -n "$ok" ] || fail "trace never became queryable via /api/public/v2/observations"

PGTZ_ACTUAL=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d langfuse -tAc "show timezone") || fail "could not query postgres timezone"
echo "$PGTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "postgres timezone is '$PGTZ_ACTUAL', not UTC"
CHTZ_ACTUAL=$("${COMPOSE[@]}" exec -T clickhouse clickhouse-client --user clickhouse --password clickhouse --query "SELECT timezone()") || fail "could not query clickhouse timezone"
echo "$CHTZ_ACTUAL" | grep -qiE '^(Etc/)?(UTC|GMT)$' || fail "clickhouse timezone is '$CHTZ_ACTUAL', not UTC"

echo "SMOKE PASS"
