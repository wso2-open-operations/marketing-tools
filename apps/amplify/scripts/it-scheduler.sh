#!/usr/bin/env bash
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Scheduler integration test (ADR-026): starts postgres:18 + the pinned akorn/scheduler image (as UID 10014,
# read-only) on a throwaway network, runs the amplify-api `scheduler-it` group (reconcile creates both jobs,
# an admin interval change updates the job, the scheduler fires POST /runs at a stub amplify-jobs on the
# host: `amplify-jobs` resolves to the host gateway, port 9598 as in tests/Config.toml), then removes
# everything. Needs Docker, openssl and bal.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCHEDULER_IMAGE="${SCHEDULER_IMAGE:-akorn/scheduler:1.7.8@sha256:07462c0684245d5f8aaed8018e4594da3ba113d5b38bb6dffcc32403108d2cf6}"
# Same Postgres pin as compose.yaml.
PG_IMAGE="${PG_IMAGE:-postgres:18@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336}"
NAME="amplify-it-sched-$$"
PORT="${AMPLIFY_IT_SCHEDULER_PORT:-18080}"
DB_PASSWORD="$(openssl rand -hex 16)"

cleanup() {
  docker rm -f "$NAME-app" "$NAME-db" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-db" --network "$NAME" \
  -e POSTGRES_DB=scheduler -e POSTGRES_USER=scheduler -e POSTGRES_PASSWORD="$DB_PASSWORD" "$PG_IMAGE" >/dev/null
ready=false
for _ in $(seq 1 60); do
  docker exec "$NAME-db" pg_isready -h 127.0.0.1 -U scheduler -d scheduler >/dev/null 2>&1 && { ready=true; break; }
  sleep 1
done
$ready || { echo "scheduler Postgres did not become ready"; exit 1; }

docker run -d --name "$NAME-app" --network "$NAME" --user 10014 --read-only \
  --add-host=amplify-jobs:host-gateway \
  -e DSN="postgres://scheduler:${DB_PASSWORD}@$NAME-db:5432/scheduler?sslmode=disable" \
  -p "127.0.0.1:${PORT}:8080" "$SCHEDULER_IMAGE" >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/health"; echo

cd "$HERE/amplify-api"
AMPLIFY_IT=true \
AMPLIFY_IT_SCHEDULER_URL="http://127.0.0.1:${PORT}" \
  bal test --groups scheduler-it
