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

# Every test tier (plan M11), in order, and everything it starts is removed again:
#   1. unit      bal test in each package (shared libraries packed to the local repository first)
#   2. IT        throwaway postgres:18 + mock_linkedin: migrate runner, repositories, the Run, DB down mid-run
#   3. scheduler scripts/it-scheduler.sh (real akorn/scheduler image) + scripts/it-scheduler-history.sh
#   4. e2e       make up -> make e2e -> make down
# Needs Docker, bal, openssl, curl, jq; host ports 19590 (api unit tests), 19596 (people-stub), 9090 (Compose), 55432, 19190/19191,
# 18080 and 18183 (scheduler ITs).
#   scripts/test-all.sh            all tiers
#   TIERS="unit it" scripts/test-all.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APPS="$HERE"
MOCK="$(cd "$HERE/linkedin/apps/mock_linkedin" 2>/dev/null && pwd || true)"
TIERS="${TIERS:-unit it scheduler e2e}"
PG="amplify-it-pg-$$"
# Same pin as compose.yaml (bump tag and digest together).
PG_IMAGE="${PG_IMAGE:-postgres:18@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336}"
PG_PORT="${AMPLIFY_IT_DB_PORT:-55432}"
LOGDIR="$(mktemp -d)"
SUMMARY=()
mock_pid=""
stack_up=false
# A failure keeps the logs for reading but still removes containers and processes, so the next run can
# bind its ports (it used to switch the whole cleanup off and leave the IT Postgres on 55432).
KEEP_LOGS=false

cleanup() {
  [ -n "$mock_pid" ] && kill "$mock_pid" >/dev/null 2>&1 || true
  [ -f "$LOGDIR/mock-deps.bak" ] && cp "$LOGDIR/mock-deps.bak" "$MOCK/Dependencies.toml"
  docker rm -f "$PG" >/dev/null 2>&1 || true
  if $stack_up; then (cd "$HERE" && make down >/dev/null 2>&1) || true; fi
  $KEEP_LOGS || rm -rf "$LOGDIR"
}
trap cleanup EXIT

# Runs `bal test` in a folder with extra env, prints the pass/fail line, keeps the totals.
bal_test() {
  local label="$1" dir="$2"; shift 2
  local log="$LOGDIR/$(echo "$label" | tr ' /' '__').log"
  if ! (cd "$dir" && env "$@" bal test ${BAL_ARGS:-} > "$log" 2>&1); then
    grep -E "\[fail\]|ERROR \[" "$log" | head -20 || true
    echo "FAILED: $label (log kept: $log)"; KEEP_LOGS=true; exit 1
  fi
  local pass fail skip
  pass=$(grep -E "^\s+[0-9]+ passing" "$log" | awk '{s+=$1} END {print s+0}')
  fail=$(grep -E "^\s+[0-9]+ failing" "$log" | awk '{s+=$1} END {print s+0}')
  skip=$(grep -E "^\s+[0-9]+ skipped" "$log" | awk '{s+=$1} END {print s+0}')
  printf '  %-34s %4d passing %2d failing %3d skipped\n' "$label" "$pass" "$fail" "$skip"
  SUMMARY+=("$label:$pass:$fail")
}

# Waits (bounded) until a Postgres container answers; fails instead of looping forever if it died.
wait_pg() {
  local container="$1" user="$2"
  for _ in $(seq 1 60); do
    docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1 && { sleep 2; return 0; }
    sleep 1
  done
  echo "Postgres container $container did not become ready"; docker logs --tail 20 "$container" || true
  return 1
}

publish_libs() {
  for lib in amplify-common amplify-domain; do
    (cd "$APPS/$lib" && bal pack >/dev/null && bal push --repository=local >/dev/null)
  done
}

tier_unit() {
  echo "== unit"
  publish_libs
  for pkg in amplify-common amplify-domain amplify-api amplify-jobs amplify-database; do
    bal_test "unit $pkg" "$APPS/$pkg"
  done
  bal_test "unit chat-stub" "$HERE/local/chat-stub"
  # directory.json is gitignored (real names); a fresh checkout needs the example copied in.
  [ -f "$HERE/local/people-stub/directory.json" ] || cp "$HERE/local/people-stub/directory.json.example" "$HERE/local/people-stub/directory.json"
  bal_test "unit people-stub" "$HERE/local/people-stub"
}

tier_it() {
  echo "== integration (postgres:18 on $PG_PORT)"
  [ -n "$MOCK" ] || { echo "mock_linkedin not found next to this project"; exit 1; }
  docker run -d --name "$PG" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:${PG_PORT}:5432" "$PG_IMAGE" >/dev/null
  wait_pg "$PG" postgres
  BAL_ARGS="--groups integration" bal_test "IT migrate runner" "$APPS/amplify-database" \
    BAL_CONFIG_VAR_ITENABLED=true BAL_CONFIG_VAR_DBPORT="$PG_PORT" BAL_CONFIG_VAR_DBPASSWORD=postgres \
    BAL_CONFIG_VAR_DBSSLMODE=DISABLE
  BAL_ARGS="--groups integration" bal_test "IT repositories + M5 flows" "$APPS/amplify-domain" \
    AMPLIFY_IT=true AMPLIFY_IT_DB_PORT="$PG_PORT"

  cp "$MOCK/Dependencies.toml" "$LOGDIR/mock-deps.bak"
  cat > "$LOGDIR/mock-it.toml" <<'TOML'
[wso2.mock_linkedin]
apiPort = 19190
wwwPort = 19191
wwwBaseUrl = "http://localhost:19191"
clientId = "it-client"
clientSecret = "it-secret"
redirectUris = ["http://localhost:3000/auth/linkedin/callback"]
enableMockAdmin = true
mockAdminKey = "it-mock-admin-key-0123456789abcdef0123"
TOML
  (cd "$MOCK" && BAL_CONFIG_FILES="$LOGDIR/mock-it.toml" bal run > "$LOGDIR/mock.log" 2>&1) &
  mock_pid=$!
  disown "$mock_pid" 2>/dev/null || true
  for _ in $(seq 1 90); do curl -s -o /dev/null "http://127.0.0.1:19190/" && break; sleep 1; done
  BAL_ARGS="--groups integration,db-down-it" bal_test "IT the Run + DB down mid-run" "$APPS/amplify-jobs" \
    AMPLIFY_IT=true AMPLIFY_IT_DB_PORT="$PG_PORT" AMPLIFY_IT_PG_CONTAINER="$PG"
  kill_tree "$mock_pid"; mock_pid=""
  docker rm -f "$PG" >/dev/null
}

# Stops one process and everything it started (`bal run` and the JVM under it). `pkill -f mock_linkedin` would
# also hit an IDE or language server with the folder open, or a parallel run.
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" >/dev/null 2>&1 || true
}

tier_scheduler() {
  echo "== scheduler IT"
  local log="$LOGDIR/sched.log"
  if ! "$HERE/scripts/it-scheduler.sh" > "$log" 2>&1; then
    tail -30 "$log"; echo "FAILED: scheduler IT"; KEEP_LOGS=true; exit 1
  fi
  local pass; pass=$(grep -E "^\s+[0-9]+ passing" "$log" | awk '{s+=$1} END {print s+0}')
  printf '  %-34s %4d passing\n' "IT scheduler" "$pass"
  SUMMARY+=("IT scheduler:$pass:0")
  local hlog="$LOGDIR/sched-history.log"
  if ! "$HERE/scripts/it-scheduler-history.sh" > "$hlog" 2>&1; then
    tail -30 "$hlog"; echo "FAILED: scheduler history retention IT"; KEEP_LOGS=true; exit 1
  fi
  pass=$(grep -E "^\s+[0-9]+ passing" "$hlog" | awk '{s+=$1} END {print s+0}')
  printf '  %-34s %4d passing\n' "IT scheduler history retention" "$pass"
  SUMMARY+=("IT scheduler history:$pass:0")
}

tier_e2e() {
  echo "== e2e (local Compose)"
  cd "$HERE"
  stack_up=true
  make up > "$LOGDIR/up.log" 2>&1 || { tail -30 "$LOGDIR/up.log"; echo "FAILED: make up"; exit 1; }
  if ! make e2e > "$LOGDIR/e2e.log" 2>&1; then tail -30 "$LOGDIR/e2e.log"; echo "FAILED: e2e"; exit 1; fi
  local oks; oks=$(grep -c "^ok:" "$LOGDIR/e2e.log" || true)
  printf '  %-34s %4d checks\n' "e2e local Compose" "$oks"
  SUMMARY+=("e2e:$oks:0")
  make down > /dev/null 2>&1; stack_up=false
}

for t in $TIERS; do "tier_$t"; done

total=0
for s in "${SUMMARY[@]}"; do total=$((total + $(echo "$s" | cut -d: -f2))); done
echo "== ALL GREEN: $total passing across: $TIERS"
