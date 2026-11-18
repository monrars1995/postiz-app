#!/usr/bin/env bash
set -euo pipefail

echo "[Heroku Entrypoint] Preparing Postiz runtime environment..."

# 1. Capture Heroku dynamic $PORT for Nginx, then pin PORT=3000 for NestJS backend
export HEROKU_PORT="${PORT:-5000}"
export PORT="3000"
export PM2_HOME="/tmp/.pm2"

mkdir -p \
  /tmp/uploads \
  /tmp/nginx_client_temp \
  /tmp/nginx_proxy_temp \
  /tmp/nginx_fastcgi_temp \
  /tmp/nginx_uwsgi_temp \
  /tmp/nginx_scgi_temp \
  /tmp/temporal/config/dynamicconfig

sed "s/__HEROKU_PORT__/${HEROKU_PORT}/g" /app/var/heroku/nginx.conf.template > /tmp/nginx.conf

# Start Nginx immediately so Heroku $PORT check passes in <1s (prevents R10 boot timeout)
nginx -c /tmp/nginx.conf -e /tmp/nginx-error.log
echo "[Heroku Entrypoint] Nginx listening on port ${HEROKU_PORT}"

# 2. Storage auto-selection: use Cloudflare R2 when credentials are provided, otherwise safe /tmp/uploads fallback
if [[ -n "${CLOUDFLARE_ACCESS_KEY:-}" && -n "${CLOUDFLARE_SECRET_ACCESS_KEY:-}" ]]; then
  export STORAGE_PROVIDER="cloudflare"
  echo "[Heroku Entrypoint] Storage provider: cloudflare (${CLOUDFLARE_BUCKETNAME:-})"
else
  export STORAGE_PROVIDER="${STORAGE_PROVIDER:-local}"
  if [[ "$STORAGE_PROVIDER" == "local" ]]; then
    export UPLOAD_DIRECTORY="/tmp/uploads"
    export NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY="/uploads"
    echo "[Heroku Entrypoint] Storage provider: local (/tmp/uploads fallback until CLOUDFLARE_ACCESS_KEY is set)"
  fi
fi

# 3. Parse DATABASE_URL and normalize connection pool limits for Heroku Postgres (20-conn cap on essential-0)
RAW_DATABASE_URL="${DATABASE_URL}"
export DATABASE_SSL_NO_VERIFY="true"
export MASTRA_PG_MAX_CONNS="${MASTRA_PG_MAX_CONNS:-2}"

eval "$(RAW_DATABASE_URL="$RAW_DATABASE_URL" node -e '
const u = new URL(process.env.RAW_DATABASE_URL);
console.log("PG_HOST=" + JSON.stringify(u.hostname));
console.log("PG_PORT=" + JSON.stringify(u.port || "5432"));
console.log("PG_USER=" + JSON.stringify(decodeURIComponent(u.username)));
console.log("PG_PASS=" + JSON.stringify(decodeURIComponent(u.password)));
console.log("PG_DB=" + JSON.stringify(u.pathname.replace(/^\//, "")));
if (!u.searchParams.has("sslmode")) u.searchParams.set("sslmode", "require");
if (!u.searchParams.has("connection_limit")) u.searchParams.set("connection_limit", "4");
if (!u.searchParams.has("pool_timeout")) u.searchParams.set("pool_timeout", "30");
console.log("NORMALIZED_DATABASE_URL=" + JSON.stringify(u.toString()));
')"
export DATABASE_URL="${NORMALIZED_DATABASE_URL}"

# 4. Start embedded Temporal Server backed by Heroku Postgres (unless external TEMPORAL_ADDRESS is configured)
if [[ -z "${TEMPORAL_ADDRESS:-}" || "${TEMPORAL_ADDRESS}" == "localhost:7233" || "${TEMPORAL_ADDRESS}" == "127.0.0.1:7233" ]]; then
  export TEMPORAL_ADDRESS="127.0.0.1:7233"
  echo "[Heroku Entrypoint] Initializing embedded Temporal schemas on PostgreSQL..."

  PGSSLMODE=require psql "$RAW_DATABASE_URL" -c "CREATE SCHEMA IF NOT EXISTS temporal; CREATE SCHEMA IF NOT EXISTS temporal_visibility;" >/dev/null

  temporal-sql-tool --plugin postgres12 --ep "$PG_HOST" -p "$PG_PORT" -u "$PG_USER" --pw "$PG_PASS" --db "$PG_DB" \
    --tls --tls-disable-host-verification --ca "search_path=temporal" --quiet setup-schema -v 0.0 || true
  temporal-sql-tool --plugin postgres12 --ep "$PG_HOST" -p "$PG_PORT" -u "$PG_USER" --pw "$PG_PASS" --db "$PG_DB" \
    --tls --tls-disable-host-verification --ca "search_path=temporal" update-schema -d /etc/temporal/schema/postgresql/v12/temporal/versioned

  temporal-sql-tool --plugin postgres12 --ep "$PG_HOST" -p "$PG_PORT" -u "$PG_USER" --pw "$PG_PASS" --db "$PG_DB" \
    --tls --tls-disable-host-verification --ca "search_path=temporal_visibility" --quiet setup-schema -v 0.0 || true
  temporal-sql-tool --plugin postgres12 --ep "$PG_HOST" -p "$PG_PORT" -u "$PG_USER" --pw "$PG_PASS" --db "$PG_DB" \
    --tls --tls-disable-host-verification --ca "search_path=temporal_visibility" update-schema -d /etc/temporal/schema/postgresql/v12/visibility/versioned

  cp /app/dynamicconfig/development-sql.yaml /tmp/temporal/config/dynamicconfig/development-sql.yaml

  PG_HOST="$PG_HOST" PG_PORT="$PG_PORT" PG_USER="$PG_USER" PG_PASS="$PG_PASS" PG_DB="$PG_DB" node -e '
const fs = require("fs");
const addr = JSON.stringify(`${process.env.PG_HOST}:${process.env.PG_PORT}`);
const db = JSON.stringify(process.env.PG_DB);
const user = JSON.stringify(process.env.PG_USER);
const pass = JSON.stringify(process.env.PG_PASS);

const yaml = `log:
  stdout: true
  level: warn

persistence:
  defaultStore: postgres-default
  visibilityStore: postgres-visibility
  numHistoryShards: 4
  datastores:
    postgres-default:
      sql:
        pluginName: "postgres12"
        databaseName: ${db}
        connectAddr: ${addr}
        connectProtocol: "tcp"
        user: ${user}
        password: ${pass}
        maxConns: 4
        maxIdleConns: 2
        maxConnLifetime: "1h"
        connectAttributes:
          search_path: "temporal"
        tls:
          enabled: true
          enableHostVerification: false
    postgres-visibility:
      sql:
        pluginName: "postgres12"
        databaseName: ${db}
        connectAddr: ${addr}
        connectProtocol: "tcp"
        user: ${user}
        password: ${pass}
        maxConns: 2
        maxIdleConns: 1
        maxConnLifetime: "1h"
        connectAttributes:
          search_path: "temporal_visibility"
        tls:
          enabled: true
          enableHostVerification: false

global:
  membership:
    maxJoinDuration: 30s
    broadcastAddress: "127.0.0.1"

services:
  frontend:
    rpc:
      grpcPort: 7233
      membershipPort: 6933
      bindOnLocalHost: true
      httpPort: 7243
  matching:
    rpc:
      grpcPort: 7235
      membershipPort: 6935
      bindOnLocalHost: true
  history:
    rpc:
      grpcPort: 7234
      membershipPort: 6934
      bindOnLocalHost: true
  worker:
    rpc:
      grpcPort: 7239
      membershipPort: 6939
      bindOnLocalHost: true

clusterMetadata:
  enableGlobalNamespace: false
  failoverVersionIncrement: 10
  masterClusterName: "active"
  currentClusterName: "active"
  clusterInformation:
    active:
      enabled: true
      initialFailoverVersion: 1
      rpcName: "frontend"
      rpcAddress: "127.0.0.1:7233"

dcRedirectionPolicy:
  policy: "noop"

archival:
  history:
    state: "disabled"
  visibility:
    state: "disabled"

namespaceDefaults:
  archival:
    history:
      state: "disabled"
    visibility:
      state: "disabled"

dynamicConfigClient:
  filepath: "/tmp/temporal/config/dynamicconfig/development-sql.yaml"
  pollInterval: "60s"
`;
fs.writeFileSync("/tmp/temporal/config/heroku.yaml", yaml);
'

  echo "[Heroku Entrypoint] Starting Temporal Server on 127.0.0.1:7233..."
  (cd /tmp/temporal && temporal-server --root /tmp/temporal --config config --env heroku --allow-no-auth start) &

  for i in $(seq 1 30); do
    if temporal operator namespace list --address 127.0.0.1:7233 >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  temporal operator namespace describe --namespace "${TEMPORAL_NAMESPACE:-default}" --address 127.0.0.1:7233 >/dev/null 2>&1 || \
    temporal operator namespace create --namespace "${TEMPORAL_NAMESPACE:-default}" --retention 72h --address 127.0.0.1:7233
  echo "[Heroku Entrypoint] Temporal namespace '${TEMPORAL_NAMESPACE:-default}' ready!"
fi

# 5. Sync Prisma schema (without re-downloading or re-generating Prisma Client)
echo "[Heroku Entrypoint] Syncing Prisma database schema..."
cd /app
./node_modules/.bin/prisma db push --schema ./libraries/nestjs-libraries/src/database/prisma/schema.prisma --skip-generate

# 6. Start Backend, Frontend, and Orchestrator via PM2 in foreground
echo "[Heroku Entrypoint] Launching Postiz services via PM2..."
exec pm2-runtime start /app/var/heroku/ecosystem.config.cjs
