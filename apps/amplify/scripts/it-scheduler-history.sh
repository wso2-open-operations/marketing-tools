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
#
# Scheduler job-history retention test (ADR-026 gap, deep review 2026-10-17). Starts postgres:18 + the
# pinned akorn/scheduler image (UID 10014, read-only) on a throwaway network, puts 40-day-old and 1-day-old
# rows into job_history, installs amplify-scheduler/history-retention.sql exactly as the compose
# `scheduler-retention` one-shot does (twice: idempotent), lets the scheduler run a job so IT writes a
# history row, and checks the old rows are gone and the recent ones kept. Then removes everything.
# Needs Docker, curl and openssl; host port AMPLIFY_IT_SCHEDULER_HISTORY_PORT (default 18183).

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCHEDULER_IMAGE="${SCHEDULER_IMAGE:-akorn/scheduler:1.7.8@sha256:07462c0684245d5f8aaed8018e4594da3ba113d5b38bb6dffcc32403108d2cf6}"
PG_IMAGE="${PG_IMAGE:-postgres:18@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336}"
NAME="amplify-it-schedhist-$$"
PORT="${AMPLIFY_IT_SCHEDULER_HISTORY_PORT:-18183}"
DB_PASSWORD="$(openssl rand -hex 16)"
API="http://127.0.0.1:${PORT}"

cleanup() {
  docker rm -f "$NAME-app" "$NAME-db" "$NAME-retention" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
psql_db() { docker exec -i "$NAME-db" psql -v ON_ERROR_STOP=1 -qtA -U scheduler -d scheduler "$@"; }

docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-db" --network "$NAME" \
  -e POSTGRES_DB=scheduler -e POSTGRES_USER=scheduler -e POSTGRES_PASSWORD="$DB_PASSWORD" "$PG_IMAGE" >/dev/null
ready=false
for _ in $(seq 1 60); do
  docker exec "$NAME-db" pg_isready -h 127.0.0.1 -U scheduler -d scheduler >/dev/null 2>&1 && { ready=true; break; }
  sleep 1
done
$ready || fail "scheduler Postgres did not become ready"

docker run -d --name "$NAME-app" --network "$NAME" --user 10014 --read-only \
  -e DSN="postgres://scheduler:${DB_PASSWORD}@$NAME-db:5432/scheduler?sslmode=disable" \
  -p "127.0.0.1:${PORT}:8080" "$SCHEDULER_IMAGE" >/dev/null
up=false
for _ in $(seq 1 30); do
  curl -fsS "$API/health" >/dev/null 2>&1 && { up=true; break; }
  sleep 1
done
$up || fail "scheduler did not answer /health"

# A disabled job, so history rows have a parent (job_history.job_id is a foreign key).
curl -fsS -X POST "$API/collections" -H 'Content-Type: application/json' \
  -d '{"id":"it-hist","name":"IT history","state":"enabled"}' >/dev/null
JOB='{"id":"it-hist-job","name":"IT history job","collectionId":"it-hist","state":"disabled",
  "schedule":"@every 1s","action":{"type":"HTTP","request":{"method":"GET","uri":"http://127.0.0.1:9/none",
  "headers":[],"body":""},"retryPolicy":{"retryCount":0,"retryInterval":"1s","deadline":"2s"}}}'
curl -fsS -X POST "$API/jobs" -H 'Content-Type: application/json' -d "$JOB" >/dev/null

psql_db <<'SQL'
INSERT INTO job_history (id, job_id, action, started, finished, status_id, retry_count, message)
SELECT 'old-' || g, 'it-hist-job', 'HTTP GET', now() - interval '40 days', now() - interval '40 days', 2, 0, 'old'
FROM generate_series(1, 50) g;
INSERT INTO job_history (id, job_id, action, started, finished, status_id, retry_count, message)
VALUES ('recent-1', 'it-hist-job', 'HTTP GET', now() - interval '1 day', now() - interval '1 day', 1, 0, 'recent');
SQL

# Install exactly as compose's scheduler-retention one-shot does, twice (idempotent).
for _ in 1 2; do
  docker run --rm --network "$NAME" -e PGHOST="$NAME-db" -e PGUSER=scheduler -e PGDATABASE=scheduler \
    -e PGPASSWORD="$DB_PASSWORD" -v "$HERE/amplify-scheduler/history-retention.sql:/retention.sql:ro" \
    --entrypoint sh "$PG_IMAGE" -c 'for i in $(seq 1 60); do
      psql -tAc "SELECT to_regclass('"'"'job_history'"'"')" | grep -q job_history &&
      exec psql -v ON_ERROR_STOP=1 -q -f /retention.sql; sleep 2; done; echo "job_history never appeared"; exit 1'
done
[ "$(psql_db -c "SELECT count(*) FROM pg_trigger WHERE tgname = 'amplify_trim_job_history'")" = "1" ] \
  || fail "trigger not installed exactly once"

# Let the scheduler itself write a history row (the job fails fast against a closed port).
curl -fsS -X PATCH "$API/jobs/it-hist-job" -H 'Content-Type: application/json' -d '{"state":"enabled"}' >/dev/null
for _ in $(seq 1 30); do
  n=$(psql_db -c "SELECT count(*) FROM job_history WHERE id NOT LIKE 'old-%' AND id <> 'recent-1'")
  [ "$n" -gt 0 ] && break
  sleep 1
done
[ "${n:-0}" -gt 0 ] || fail "the scheduler wrote no history row"
curl -fsS -X PATCH "$API/jobs/it-hist-job" -H 'Content-Type: application/json' -d '{"state":"disabled"}' >/dev/null

old=$(psql_db -c "SELECT count(*) FROM job_history WHERE started < now() - interval '30 days'")
recent=$(psql_db -c "SELECT count(*) FROM job_history WHERE id = 'recent-1'")
[ "$old" = "0" ] || fail "$old rows older than 30 days survived the scheduler's own insert"
[ "$recent" = "1" ] || fail "a 1-day-old row was trimmed"
echo "ok: 30-day job_history retention trims on the scheduler's own inserts ($n new rows, old rows gone, recent kept)"
echo "     1 passing"
