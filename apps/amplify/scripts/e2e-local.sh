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
# Local end-to-end smoke test (plan M8a) against `make up`. DEV-ONLY: uses ADR-023 dev JWTs.
#   register campaign -> scheduler fires amplify-run -> jobs POST /runs -> chat-stub got the card
#   -> connect LinkedIn via mock OAuth (scripted redirect) -> share -> run -> points -> leaderboard
#   -> dashboards (real HTTP, real database): role gating, the repost just made shows on every board
# Needs: curl, jq, docker compose. Exits non-zero on the first failed step.
set -euo pipefail
cd "$(dirname "$0")/.."

API="${API:-http://localhost:9090}"
COMPOSE=(scripts/compose.sh)
# The e2e scripts the mock's sign-in page, so it can't run against real LinkedIn.
case "$(sed -n 's/^LINKEDIN_USE_MOCK=//p' local/.env | tail -1 | tr '[:upper:]' '[:lower:]')" in
  false | 0 | no) echo "e2e needs the mock: set LINKEDIN_USE_MOCK=true in local/.env and restart the stack" >&2; exit 1 ;;
esac
# The card check below reads the chat-stub, which only the Club webhook path posts to.
case "$(sed -n 's/^AMPLIFY_ON_WEBHOOK=//p' local/.env | tail -1 | tr '[:upper:]' '[:lower:]')" in
  true | 1 | yes) ;;
  *) echo "e2e needs the webhook path: set AMPLIFY_ON_WEBHOOK=true in local/.env and restart the stack" >&2; exit 1 ;;
esac
# ... and only while the webhook URL is the stub. A real webhook (`GOOGLE_CHAT_WEBHOOK_URL` = the dev test space)
# takes every card out of the stack, so the card check would wait out its timeout with the posts already sent.
case "$(sed -n 's/^GOOGLE_CHAT_WEBHOOK_URL=//p' local/.env | tail -1)" in
  ''|*chat-stub*|*localhost:9095*|*127.0.0.1:9095*) ;;
  *) echo "e2e reads the chat-stub: unset GOOGLE_CHAT_WEBHOOK_URL in local/.env (or point it at chat-stub) and restart the stack" >&2; exit 1 ;;
esac
# Posts must belong to the page amplify-api is configured with (local/.env, default WSO2's page).
ORG_URN=$(sed -n 's/^WSO2_ORGANIZATION_URN=//p' local/.env | tail -1)
ORG_URN=${ORG_URN:-urn:li:organization:1477}
MINT=local/dev-jwt/mint-dev-jwt.sh
RUN_ID="$(date +%s)"
# One fixed employee: the mock signs every authorization in as the same LinkedIn member, and a member URN
# belongs to one employee (B13). Reruns disconnect first, so the OAuth leg runs every time.
EMP_SUB="e2e-employee"
EMP_EMAIL="e2e.employee@example.com"
# On a stack someone has been using, the mock member may already belong to another employee, and it stays
# theirs even after they disconnect (B13: unique member_urn, removed rows included). Then this run acts as
# that employee: relinking your own member is allowed. Their shares and points get the e2e post's activity.
holder=$("${COMPOSE[@]}" exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d amplify -At -F "|" -c "
  SELECT c.employee_id, e.email FROM connection.member_connection c JOIN identity.employee e USING (employee_id)
  WHERE c.employee_id <> '"'e2e-employee'"' LIMIT 1"' 2>/dev/null || true)
if [[ -n "$holder" ]]; then
  IFS='|' read -r EMP_SUB EMP_EMAIL <<<"$holder"
  echo "note: the mock LinkedIn member belongs to $EMP_EMAIL; running the employee steps as them"
fi

ADMIN_JWT="$($MINT token e2e-admin admin.e2e@example.com amplify_admin amplify_marketing)"
EMP_JWT="$($MINT token "$EMP_SUB" "$EMP_EMAIL")"

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# call <jwt> <method> <path> [json body] -> body on stdout; fails on non-2xx
call() {
  local jwt="$1" method="$2" path="$3" body="${4:-}" out code
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
    -H "x-jwt-assertion: $jwt" -H 'Content-Type: application/json' \
    -H "X-Correlation-ID: e2e-${RUN_ID}" ${body:+--data "$body"})
  if [[ "$code" != 2* ]]; then cat "$out" >&2; rm -f "$out"; fail "$method $path -> $code"; fi
  cat "$out"; rm -f "$out"
}
# wait_for <seconds> <description> <command...>: retry until the command succeeds
wait_for() {
  local secs="$1" what="$2"; shift 2
  for ((i = 0; i < secs; i += 2)); do
    if "$@" >/dev/null 2>&1; then echo "ok: $what"; return 0; fi
    sleep 2
  done
  fail "timed out after ${secs}s waiting for: $what"
}
internal_get() { "${COMPOSE[@]}" exec -T "$1" wget -qO- "$2"; }

step "health"
curl -fsS "$API/ready" | jq -e '.status == "UP"' >/dev/null || fail "amplify-api not ready"

step "run.schedule -> @every 10s (pushed to the scheduler)"
version=$(call "$ADMIN_JWT" GET /admin/settings | jq -r '.settings[] | select(.key == "run.schedule") | .version')
call "$ADMIN_JWT" PUT /admin/settings \
  "{\"changes\":[{\"key\":\"run.schedule\",\"value\":\"@every 10s\",\"version\":$version}]}" \
  | jq -e '.schedulerSync == "SYNCED" or .schedulerSync.status == "SYNCED"' >/dev/null \
  || fail "scheduler sync did not report SYNCED"

step "register campaign"
TITLE="E2E campaign ${RUN_ID}"
campaign=$(call "$ADMIN_JWT" POST /campaigns "$(jq -nc --arg t "$TITLE" --arg u "urn:li:share:${RUN_ID}" --arg o "$ORG_URN" '{
  resourceUrn: $u, ownerUrn: $o, title: $t, summary: "Local e2e smoke test",
  resourceUrl: "https://www.linkedin.com/feed/update/\($u)", categoryCode: "PRODUCT", tags: ["e2e"]}')")
CAMPAIGN_ID=$(jq -r '.campaign.id // .id' <<<"$campaign")
echo "campaign $CAMPAIGN_ID"

step "scheduler -> amplify-jobs POST /runs -> chat-stub got the card"
card_posted() { internal_get chat-stub http://localhost:9095/stub/messages | grep -q "$TITLE"; }
wait_for 60 "Google Chat card for '$TITLE'" card_posted
run_ok() { internal_get amplify-api http://scheduler:8080/jobs/amplify-run/history | grep -q '"status":"completed"'; }
wait_for 30 "scheduler job history shows a successful amplify-run" run_ok

step "connect LinkedIn via mock OAuth"
if call "$EMP_JWT" GET /me | jq -e '.linkedin.status | IN("NOT_CONNECTED", "REMOVED") | not' >/dev/null; then
  call "$EMP_JWT" DELETE /connections/linkedin >/dev/null
  echo "rerun: removed the previous connection"
fi
start=$(call "$EMP_JWT" POST /connections/linkedin/start '{}')
AUTH_URL=$(jq -r '.authorizationUrl' <<<"$start")
[[ "$AUTH_URL" == http://localhost:19091/* ]] || fail "authorization URL is not browser-reachable: $AUTH_URL"
redirect=$(curl -sS -o /dev/null -w '%{redirect_url}' "$AUTH_URL")
CODE=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$redirect")
STATE=$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$redirect")
[[ -n "$CODE" && -n "$STATE" ]] || fail "mock OAuth did not redirect with code+state: $redirect"
# `complete` also takes the callback page the browser landed on, and refuses anything but the configured
# redirect URI (open-redirect guard). Read it from local/.env rather than repeating it here.
REDIRECT_URI=$(sed -n 's/^LINKEDIN_REDIRECT_URI=//p' local/.env | tail -1)
[[ -n "$REDIRECT_URI" ]] || fail "LINKEDIN_REDIRECT_URI is not set in local/.env"
call "$EMP_JWT" POST /connections/linkedin/complete \
  "{\"code\":\"$CODE\",\"state\":\"$STATE\",\"redirectUri\":\"$REDIRECT_URI\"}" >/dev/null
call "$EMP_JWT" GET /me | jq -e '.linkedin.status == "ACTIVE"' >/dev/null || fail "connection not ACTIVE"
echo "ok: LinkedIn ACTIVE"

step "share (REPOST)"
call "$EMP_JWT" POST "/campaigns/$CAMPAIGN_ID/shares" '{"kind":"REPOST"}' >/dev/null
published() { call "$EMP_JWT" GET /me/shares | jq -e --arg c "$CAMPAIGN_ID" \
  '[.. | objects | select(.campaignId? == $c and .status? == "PUBLISHED")] | length > 0'; }
wait_for 60 "share PUBLISHED on mock LinkedIn" published

step "points + leaderboard"
has_points() { call "$EMP_JWT" GET /me/points | jq -e '[.. | objects | .total? // .totalPoints? // .points? | numbers] | max > 0'; }
wait_for 60 "points awarded" has_points
call "$EMP_JWT" GET /me/points | jq -c .
on_board() { call "$EMP_JWT" GET /leaderboard | grep -q "$EMP_EMAIL"; }
wait_for 30 "employee on the leaderboard" on_board
call "$EMP_JWT" GET /leaderboard | jq -c '.personal // .'

step "dashboards: role gating, then the numbers behind the share above"
# A plain employee is refused every board; an amplify_* role reads them (ADR-036).
for board in operations campaigns participation glance scorecard; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "x-jwt-assertion: $EMP_JWT" "$API/dashboards/$board")
  [[ "$code" == 403 ]] || fail "employee GET /dashboards/$board -> $code (want 403)"
done
echo "ok: plain employee gets 403 on all five boards"
SLT_JWT="$($MINT token e2e-slt slt.e2e@example.com amplify_slt)"
ops=$(call "$SLT_JWT" GET /dashboards/operations)
echo "$ops" | jq -e --arg c "$CAMPAIGN_ID" '[.campaigns[] | select(.campaignId == $c and .reposts >= 1)] | length == 1' >/dev/null \
  || fail "operations board does not show the e2e campaign with its repost"
echo "$ops" | jq -e '.kpis.repostsThisMonth >= 1 and .kpis.peopleConnected >= 1 and .kpis.pointsThisMonth >= 0' >/dev/null \
  || fail "operations kpis are wrong: $(echo "$ops" | jq -c .kpis)"
call "$SLT_JWT" GET "/dashboards/campaigns?campaignId=$CAMPAIGN_ID" \
  | jq -e --arg c "$CAMPAIGN_ID" '.selected.campaignId == $c and .selected.reposts >= 1 and (.selected.byDay | length) == 7' >/dev/null \
  || fail "campaign board does not detail the e2e campaign"
call "$SLT_JWT" GET /dashboards/participation | jq -e '.funnel.connected >= 1 and .funnel.reposted >= 1' >/dev/null \
  || fail "participation funnel does not count the sharer"
call "$SLT_JWT" GET /dashboards/glance | jq -e '.reposts.thisMonth >= 1 and (.monthly | length) == 6' >/dev/null \
  || fail "glance numbers are wrong"
call "$SLT_JWT" GET /dashboards/scorecard | jq -e '(.measures | length) == 7 and all(.measures[]; .status == "ON_TRACK" or .status == "WATCH")' >/dev/null \
  || fail "scorecard is not seven measures with a status"
call "$EMP_JWT" GET "/leaderboard/groups?by=TEAM&sort=participation&dir=desc" | jq -e '.entries | type == "array"' >/dev/null \
  || fail "group leaderboard failed"
call "$EMP_JWT" GET /headcount | jq -e '.total >= 1' >/dev/null || fail "headcount failed"
echo "ok: dashboards, group boards and headcount answer from the real database"

step "restore run.schedule -> @every 5m"
version=$(call "$ADMIN_JWT" GET /admin/settings | jq -r '.settings[] | select(.key == "run.schedule") | .version')
call "$ADMIN_JWT" PUT /admin/settings \
  "{\"changes\":[{\"key\":\"run.schedule\",\"value\":\"@every 5m\",\"version\":$version}]}" >/dev/null

printf '\nE2E PASSED\n'
