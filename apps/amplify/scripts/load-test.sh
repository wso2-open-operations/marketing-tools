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

# Load test (plan M11) against the running local Compose stack (`make up`): seeds 1k employees + 50k
# ledger rows, rebuilds recognition, then runs k6 (grafana/k6 image on the Compose network, nothing
# installed on the host) at RATE req/s per endpoint for DURATION. Exit code follows the k6 thresholds
# (p95 < 50 ms for /leaderboard, /me/points, /team). LOCAL ONLY: the seed writes straight to Postgres.
#
#   scripts/load-test.sh                 # RATE=50 DURATION=60s
#   RATE=100 DURATION=120s scripts/load-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

K6_IMAGE="${K6_IMAGE:-grafana/k6:1.0.0@sha256:f21270290d702cbf0a7d6ba5d7ed100b63bcb233b558b885ed787547b3488279}"
COMPOSE=(scripts/compose.sh)
NETWORK="${NETWORK:-wso2-amplify_internal}"
work="$PWD/local/.load"; rm -rf "$work"; mkdir -p "$work"; trap 'rm -rf "$work"' EXIT  # under the project: Docker Desktop may not share $TMPDIR

echo "== seed 1,000 employees + 50,000 ledger rows"
"${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -q -U postgres -d amplify < scripts/load/seed-load.sql

echo "== rebuild recognition (amplify-jobs)"
# The internal key (full access) is already in amplify-api's environment; the scheduler key would get a 403 here.
"${COMPOSE[@]}" exec -T amplify-api sh -c \
  'wget -qO- --header "X-Amplify-Internal-Key: $BAL_CONFIG_VAR_INTERNALAPIKEY" --post-data "" http://amplify-jobs:9091/maintenance/rebuild-recognition' 
echo

echo "== mint dev JWTs (1 PO + 200 employees)"
{
  printf '['
  printf '"%s"' "$(local/dev-jwt/mint-dev-jwt.sh token lt-po lt-po@example.com amplify_po)"
  for n in $(seq 1 200); do
    id=$(printf 'lt-%04d' "$(( (n * 5) % 1000 + 1 ))")
    printf ',"%s"' "$(local/dev-jwt/mint-dev-jwt.sh token "$id" "$id@example.com")"
  done
  printf ']'
} > "$work/tokens.json"
cp scripts/load/amplify-load.js "$work/"

echo "== warm-up (30 s at the test rate, not measured: JIT and pool warm-up)"
docker run --rm --network "$NETWORK" -v "$work:/scripts:ro" -e RATE="${RATE:-50}" -e DURATION=30s "$K6_IMAGE" \
  run --quiet --no-thresholds /scripts/amplify-load.js > /dev/null 2>&1 || true

echo "== k6 run: RATE=${RATE:-50}/s per endpoint for ${DURATION:-60s}"
docker run --rm --network "$NETWORK" -v "$work:/scripts:ro" -e RATE="${RATE:-50}" -e DURATION="${DURATION:-60s}" \
  "$K6_IMAGE" run /scripts/amplify-load.js
