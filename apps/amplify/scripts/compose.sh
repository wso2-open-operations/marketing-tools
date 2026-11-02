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

# docker compose for the local stack: `--env-file local/.env`, plus the LinkedIn mock/real switch.
#
#   LINKEDIN_USE_MOCK=true   (default) amplify-api and amplify-jobs talk to the mock-linkedin container
#   LINKEDIN_USE_MOCK=false  they talk to real LinkedIn with your non-prod app (LINKEDIN_REAL_CLIENT_ID /
#                            LINKEDIN_REAL_CLIENT_SECRET in local/.env). A share then publishes to a real feed.
#
# Compose can only test "empty or not", so the boolean is turned into the right LINKEDIN_* values here
# (exported variables beat --env-file). Use this instead of `docker compose --env-file local/.env`:
#   scripts/compose.sh up -d --build        scripts/compose.sh ps        scripts/compose.sh logs -f amplify-jobs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/local/.env"
val() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }

mock="$(val LINKEDIN_USE_MOCK)"
case "$(printf '%s' "${mock:-true}" | tr '[:upper:]' '[:lower:]')" in
  true | 1 | yes)
    export LINKEDIN_API_BASE_URL=http://mock-linkedin:9090
    export LINKEDIN_OAUTH_BASE_URL=http://mock-linkedin:9091
    export LINKEDIN_AUTHORIZE_BASE_URL=http://localhost:19091
    export LINKEDIN_ID_TOKEN_VALIDATION=false
    unset LINKEDIN_APP_CLIENT_ID LINKEDIN_APP_CLIENT_SECRET
    echo "LinkedIn: MOCK (mock-linkedin container)" >&2
    ;;
  false | 0 | no)
    id="$(val LINKEDIN_REAL_CLIENT_ID)"
    secret="$(val LINKEDIN_REAL_CLIENT_SECRET)"
    if [ -z "$id" ] || [ -z "$secret" ]; then
      echo "LINKEDIN_USE_MOCK=false needs LINKEDIN_REAL_CLIENT_ID and LINKEDIN_REAL_CLIENT_SECRET in local/.env" >&2
      exit 1
    fi
    export LINKEDIN_API_BASE_URL=https://api.linkedin.com
    export LINKEDIN_OAUTH_BASE_URL=https://www.linkedin.com
    export LINKEDIN_AUTHORIZE_BASE_URL=            # empty = reuse the OAuth base
    export LINKEDIN_ID_TOKEN_VALIDATION="$(val LINKEDIN_REAL_ID_TOKEN_VALIDATION)"
    export LINKEDIN_ID_TOKEN_VALIDATION="${LINKEDIN_ID_TOKEN_VALIDATION:-true}"
    export LINKEDIN_APP_CLIENT_ID="$id" LINKEDIN_APP_CLIENT_SECRET="$secret"
    echo "LinkedIn: REAL (api.linkedin.com). Shares publish to a real feed." >&2
    ;;
  *)
    echo "LINKEDIN_USE_MOCK must be true or false (got '$mock')" >&2
    exit 1
    ;;
esac

exec docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" "$@"
