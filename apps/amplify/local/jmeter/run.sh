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

# JMeter performance suite (master.jmx) for the Ballerina modules: amplify-api, amplify-domain (through
# the API reads it serves), amplify-common (probes and shared error paths) and amplify-jobs. JMeter runs
# in Docker on the Compose network because amplify-jobs has no host port. LOCAL ONLY: the seed writes
# straight to Postgres. Needs `make up` first.
#
#   local/jmeter/run.sh                                 # all modules, 120 s, p95 target 50 ms
#   MODULES="api domain" DURATION=300 local/jmeter/run.sh
#   RUN_JOBS=1 local/jmeter/run.sh                      # also POST /runs (posts to LinkedIn and chat-stub)
#   SEED=0 local/jmeter/run.sh                          # keep the data you already have
#   EXTRA_JMETER_ARGS="-Japi.threads=40" local/jmeter/run.sh
#
# Results: local/jmeter/results/<timestamp>/ (results.jtl, summary.md, report/index.html).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

JMETER_IMAGE="${JMETER_IMAGE:-justb4/jmeter:5.5@sha256:088ac52b759a198a5afa5ae13d0a6306e9f2017d71ad140ff57427f6930406f7}"
NETWORK="${NETWORK:-wso2-amplify_internal}"
MODULES="${MODULES:-api domain common jobs}"
DURATION="${DURATION:-120}"
RAMP="${RAMP:-30}"
THINK_MS="${THINK_MS:-200}"
EMPLOYEES="${EMPLOYEES:-200}"
SEED="${SEED:-1}"
RUN_JOBS="${RUN_JOBS:-0}"
P95_TARGET_MS="${P95_TARGET_MS:-50}"
COMPOSE=(scripts/compose.sh)

die() { echo "error: $*" >&2; exit 1; }

# Dev JWTs live 30 minutes (local/dev-jwt/mint-dev-jwt.sh), so the run has to finish inside that.
(( DURATION + RAMP <= 1500 )) || die "DURATION + RAMP must be 1500 s or less: the dev tokens expire after 30 minutes"
(( EMPLOYEES >= 1 && EMPLOYEES <= 1000 )) || die "EMPLOYEES must be 1..1000 (ids lt-0001..lt-1000 come from the seed)"

docker network inspect "$NETWORK" >/dev/null 2>&1 || die "network $NETWORK not found: run 'make up' first"
"${COMPOSE[@]}" exec -T amplify-api wget -qO- http://localhost:9090/ready >/dev/null \
  || die "amplify-api is not ready: check 'make ps' and 'make logs'"

if [[ "$SEED" == 1 ]]; then
  echo "== seed 1,000 employees + 50,000 ledger rows (same seed as scripts/load-test.sh)"
  "${COMPOSE[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -q -U postgres -d amplify < scripts/load/seed-load.sql
  "${COMPOSE[@]}" exec -T amplify-api wget -qO- --post-data '' http://amplify-jobs:9091/maintenance/rebuild-recognition >/dev/null
fi

run="$here/results/$(date +%Y%m%d-%H%M%S)"
work="$run/.work"                      # tokens only: deleted on exit
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

echo "== mint dev JWTs (1 PO + $EMPLOYEES employees)"
mint() { local/dev-jwt/mint-dev-jwt.sh token "$@"; }
mint lt-po lt-po@example.com amplify_po > "$work/po.csv"
: > "$work/employees.csv"
for n in $(seq 1 "$EMPLOYEES"); do
  id=$(printf 'lt-%04d' "$n")
  echo "$(mint "$id" "$id@example.com"),$id" >> "$work/employees.csv"
done

# Thread-count overrides: a module that is not in MODULES gets 0 threads. jobs has two groups.
flags=()
for m in api domain common; do
  [[ " $MODULES " == *" $m "* ]] || flags+=("-J$m.threads=0")
done
if [[ " $MODULES " != *" jobs "* ]]; then
  flags+=("-Jjobs.threads=0" "-Jjobs.maintenance.threads=0" "-Jjobs.run.threads=0")
elif [[ "$RUN_JOBS" == 1 ]]; then
  flags+=("-Jjobs.run.threads=2")
fi

echo "== JMeter: modules [$MODULES], ${DURATION} s (ramp ${RAMP} s), think ${THINK_MS} ms"
# shellcheck disable=SC2086  # EXTRA_JMETER_ARGS is meant to split into words
docker run --rm --network "$NETWORK" \
  -e JVM_XMS=1024 -e JVM_XMN=512 -e JVM_XMX=2048 \
  -v "$run:/results" -v "$work:/work:ro" -v "$here:/plan:ro" \
  "$JMETER_IMAGE" \
  -n -t /plan/master.jmx \
  -l /results/results.jtl -j /results/jmeter.log \
  -e -o /results/report \
  -Jduration="$DURATION" -Jramp="$RAMP" -Jthink.ms="$THINK_MS" \
  -Jemployees.file=/work/employees.csv -Jpo.file=/work/po.csv \
  ${flags[@]+"${flags[@]}"} ${EXTRA_JMETER_ARGS:-} \
  || die "JMeter exited non-zero: see $run/jmeter.log"

echo
echo "Summary: $run/summary.md"
echo "HTML report: $run/report/index.html"
echo
python3 "$here/summarize.py" "$run/results.jtl" --target-ms "$P95_TARGET_MS" | tee "$run/summary.md"
