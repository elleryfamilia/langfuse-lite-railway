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
