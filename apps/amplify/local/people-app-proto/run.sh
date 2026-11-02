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
# LOCAL PROTOTYPE (D13): amplify-api reads the REAL people-app GET /employees/basic-info as a service
# client, through a gateway stand-in, to prove the people-app "service clients" change end to end.
#
#   local/people-app-proto/run.sh up      build people-app, start MySQL + people-app + gateway, point amplify-api at it
#   local/people-app-proto/run.sh demo    the checks (curl), printed as PASS/FAIL
#   local/people-app-proto/run.sh off     restart people-app with NO service clients listed (the "before")
#   local/people-app-proto/run.sh down    remove the prototype, point amplify-api back at people-stub
#
# Needs the Compose stack up (make up), Docker, curl, jq, openssl (people-app builds in its Ballerina image). PEOPLE_BACKEND overrides the
# people-app backend folder (default: the people-ops-suite submodule next to this repo).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# Workspace layout: projects/marketing-tools/apps/amplify -> projects/people-ops-suite.
PEOPLE_BACKEND="${PEOPLE_BACKEND:-$ROOT/../../../people-ops-suite/apps/people-app/backend}"
NET=wso2-amplify_internal
STATE="$HERE/.proto.env"
CLIENT_ID=amplify-api-local
MYSQL_IMAGE=mysql:8.0@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b
NODE_IMAGE=node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402
# glibc, not alpine: netty's native TLS library doesn't load on musl/aarch64.
JRE_IMAGE=eclipse-temurin:21-jre@sha256:227118764cccd3c3294617061aaa93a08309c63a395eefa83e6b35032992ea99
COMPOSE=("$ROOT/scripts/compose.sh")

mysql_q() { docker exec -i -e MYSQL_PWD="$MYSQL_PASSWORD" people-proto-mysql mysql -uroot "$@"; }

render_config() {  # $1 = bare client id (a quoted TOML key never matches) allowed to read the directory, or empty for none
  local route=""; [ -n "$1" ] && route="$1 = [\"GET employees/basic-info\"]"
  sed -e "s|__MYSQL_PASSWORD__|$MYSQL_PASSWORD|g" -e "s|__CLIENT_ROUTE__|$route|" \
    "$HERE/Config.toml.template" > "$HERE/Config.toml"
  chmod 600 "$HERE/Config.toml"
}

start_app() {
  docker rm -f people-proto-app >/dev/null 2>&1 || true
  docker run -d --name people-proto-app --network "$NET" -p 127.0.0.1:19094:9090 \
    -v "$PEOPLE_BACKEND/target/bin/people.jar:/app/people.jar:ro" -v "$HERE/Config.toml:/app/Config.toml:ro" \
    -w /app "$JRE_IMAGE" java -jar people.jar >/dev/null
  for _ in $(seq 60); do
    curl -s -o /dev/null "http://127.0.0.1:19094/employees/basic-info" && return 0
    sleep 1
  done
  docker logs people-proto-app | tail -20; echo "people-app did not start"; exit 1
}

point_api() {  # $1 = directory URL, $2 = token URL, $3 = client id, $4 = secret
  PEOPLE_DIRECTORY_URL="$1" PEOPLE_DIRECTORY_TOKEN_URL="$2" PEOPLE_DIRECTORY_CLIENT_ID="$3" \
    PEOPLE_DIRECTORY_CLIENT_SECRET="$4" "${COMPOSE[@]}" up -d --wait amplify-api >/dev/null
}

up() {
  docker network inspect "$NET" >/dev/null 2>&1 || { echo "Compose stack not up: run 'make up' first"; exit 1; }
  # Built in the Ballerina image the package names (Ballerina.toml `distribution`): a newer local `bal`
  # (2201.13.x) produced a jar that failed at start-up with NoClassDefFoundError in database/types.bal.
  local dist; dist=$(sed -n 's/^distribution *= *"\(.*\)"/\1/p' "$PEOPLE_BACKEND/Ballerina.toml")
  docker run --rm -u root -v "$PEOPLE_BACKEND":/src -w /src "ballerina/ballerina:$dist" \
    sh -c "bal build --locking-mode=locked >/dev/null && chown -R $(id -u):$(id -g) target Dependencies.toml"
  MYSQL_PASSWORD=$(openssl rand -hex 16); CLIENT_SECRET=$(openssl rand -hex 16)
  printf 'MYSQL_PASSWORD=%s\nCLIENT_SECRET=%s\n' "$MYSQL_PASSWORD" "$CLIENT_SECRET" > "$STATE"; chmod 600 "$STATE"

  docker rm -f people-proto-mysql >/dev/null 2>&1 || true
  docker run -d --name people-proto-mysql --network "$NET" -e MYSQL_ROOT_PASSWORD="$MYSQL_PASSWORD" "$MYSQL_IMAGE" >/dev/null
  for _ in $(seq 90); do mysql_q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  mysql_q -e "CREATE DATABASE people; CREATE DATABASE promotion;"
  mysql_q people < "$PEOPLE_BACKEND/resources/people_app_creation.sql"
  mysql_q people < "$HERE/seed.sql"

  # Gateway first: people-app's own outbound clients (wso2_coin, qr) fetch an OAuth token at start-up,
  # so their token URLs point at the gateway's /token (client "unused").
  docker rm -f people-proto-gateway >/dev/null 2>&1 || true
  docker run -d --name people-proto-gateway --network "$NET" -p 127.0.0.1:19093:8080 \
    -e CLIENTS="$CLIENT_ID:$CLIENT_SECRET,unused:unused" -e UPSTREAM=http://people-proto-app:9090 \
    -v "$HERE/gateway.mjs:/gateway.mjs:ro" "$NODE_IMAGE" node /gateway.mjs >/dev/null
  render_config "$CLIENT_ID"
  start_app


  point_api http://people-proto-gateway:8080/employees/basic-info http://people-proto-gateway:8080/token \
    "$CLIENT_ID" "$CLIENT_SECRET"
  echo "Up: people-app :19094 (direct), gateway :19093, amplify-api reads the directory through the gateway."
}

off() {
  # shellcheck disable=SC1090
  source "$STATE"
  render_config ""
  start_app
  # Drops amplify-api's cached team index, so the next read goes back to people-app.
  "${COMPOSE[@]}" restart amplify-api >/dev/null
  echo "people-app restarted with no service clients listed (the behaviour before the change)."
}

down() {
  docker rm -f people-proto-gateway people-proto-app people-proto-mysql >/dev/null 2>&1 || true
  rm -f "$HERE/Config.toml" "$STATE"
  point_api "" "" "" ""
  echo "Prototype removed; amplify-api is back on people-stub."
}

# ---- demo -----------------------------------------------------------------------------------------

pass=0; fail=0
check() {  # name, expected, actual
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass + 1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail + 1)); fi
}
jwt() { local h p; h=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  p=$(printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='); echo "$h.$p.unsigned"; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

demo() {
  # shellcheck disable=SC1090
  source "$STATE"
  local gw=http://127.0.0.1:19093 app=http://127.0.0.1:19094 token
  token=$(curl -s -X POST "$gw/token" -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET" | jq -r .access_token)

  echo "== people-app, service client through the gateway"
  local rows; rows=$(curl -s -H "Authorization: Bearer $token" "$gw/employees/basic-info")
  check "directory read as $CLIENT_ID" "13" "$(jq length <<<"$rows")"
  check "one employee record refused" "403" "$(status -H "Authorization: Bearer $token" "$gw/employees/dff9b5e5-625f-46fa-b529-2bccf9d89ddc")"
  check "personal info refused" "403" "$(status -H "Authorization: Bearer $token" "$gw/employees/dff9b5e5-625f-46fa-b529-2bccf9d89ddc/personal-info")"
  check "search refused" "403" "$(status -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' "$gw/employees/search")"

  echo "== people-app, other callers unchanged"
  check "unlisted client id refused" "403" "$(status -H "x-jwt-assertion: $(jwt '{"azp":"someone-else","aut":"APPLICATION"}')" "$app/employees/basic-info")"
  check "listed id on a user token (no email) refused" "500" "$(status -H "x-jwt-assertion: $(jwt '{"azp":"'"$CLIENT_ID"'","aut":"APPLICATION_USER"}')" "$app/employees/basic-info")"
  check "employee user reads the directory" "200" "$(status -H "x-jwt-assertion: $(jwt '{"email":"avery@example.com","groups":["people-employee"]}')" "$app/employees/basic-info")"
  check "user without a people group refused" "403" "$(status -H "x-jwt-assertion: $(jwt '{"email":"avery@example.com","groups":[]}')" "$app/employees/basic-info")"

  echo "== amplify-api My Team from the real directory"
  local mint="$ROOT/local/dev-jwt/mint-dev-jwt.sh" board
  board=$(curl -s -H "x-jwt-assertion: $("$mint" token avery avery@example.com amplify_po)" http://127.0.0.1:9090/leaderboard)
  check "teamStatus" "OK" "$(jq -r .teamStatus <<<"$board")"
  check "team is the sub-team" "PO" "$(jq -r .myTeam.teamName <<<"$board")"
  check "headcount (Avery, Blake, Casey, Finley, Kai)" "5" "$(jq -r .myTeam.headcount <<<"$board")"

  echo "== $pass passed, $fail failed"
  [[ $fail -eq 0 ]]
}

case "${1:-}" in
  up) up ;; demo) demo ;; off) off ;; down) down ;;
  *) sed -n '18,26p' "$0"; exit 1 ;;
esac
