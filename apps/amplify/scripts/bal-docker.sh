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

# Runs `bal` for one Amplify package inside Docker, for machines that have no `bal` on PATH.
#
#   scripts/bal-docker.sh [--apps DIR] [--repo DIR] [--network NAME] [-e KEY=VALUE]... <package> <bal args...>
#   scripts/bal-docker.sh warm <package>          fill the private repository with the locked std-lib versions
#
# Examples (from apps/amplify):
#   scripts/bal-docker.sh warm amplify-common
#   scripts/bal-docker.sh amplify-common pack
#   scripts/bal-docker.sh amplify-common push --repository=local
#   scripts/bal-docker.sh amplify-common test
#
# What it takes care of, so a run doesn't have to:
#   - openssl: the image (scripts/bal-docker/Dockerfile) has it, built on first use.
#   - --offline: added for pack, build, test and run, never for push (push has no such option and fails).
#   - the local Ballerina repository: one per checkout under ~/.cache/amplify-bal/, so two branches or two
#     agents never overwrite each other's amplify_common / amplify_domain. Override with --repo.
#   - another branch: --apps /path/to/other/checkout/apps/amplify runs the same package against that checkout.
#   - bala order: pack and push amplify-common, then amplify-domain, then test api and jobs.
# Set AMPLIFY_BAL_ONLINE=1 to leave --offline off (the one-time `warm` step always runs online).
# Docker Desktop only mounts paths under your home folder, so keep checkouts and --repo there, not in /tmp.
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$TOOLS"
IMAGE="${AMPLIFY_BAL_IMAGE:-amplify-bal-test:2201.13.3}"
REPO=""
NETWORK=""
ENVS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apps) HERE="$(cd "$2" && pwd)"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    -e) ENVS+=(-e "$2"); shift 2 ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || { sed -n '/^# Runs/,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 2; }

if [ -z "$REPO" ]; then
  KEY="$(printf %s "$HERE" | shasum | cut -c1-12)"
  REPO="${XDG_CACHE_HOME:-$HOME/.cache}/amplify-bal/$KEY/repositories"
fi
mkdir -p "$REPO"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "bal-docker: building $IMAGE (ballerina + openssl), once" >&2
  docker build -q -t "$IMAGE" -f "$TOOLS/scripts/bal-docker/Dockerfile" "$TOOLS/scripts/bal-docker" >/dev/null
fi

run() {
  local pkg="$1"; shift
  local net=(); [ -z "$NETWORK" ] || net=(--network "$NETWORK")
  docker run --rm --user root -e HOME=/root ${ENVS[@]+"${ENVS[@]}"} ${net[@]+"${net[@]}"} \
    -v "$REPO":/root/.ballerina/repositories -v "$HERE":/work -w "/work/$pkg" \
    --entrypoint bal "$IMAGE" "$@"
}

if [ "$1" = "warm" ]; then
  # The lock files pin std-lib versions the image doesn't bundle. One online pack fetches them into $REPO.
  run "$2" pack >/dev/null
  exit 0
fi

PKG="$1"; shift
SUB="$1"
case "$SUB" in
  pack|build|test|run) [ "${AMPLIFY_BAL_ONLINE:-}" = 1 ] || set -- "$@" --offline ;;
esac
run "$PKG" "$@"
