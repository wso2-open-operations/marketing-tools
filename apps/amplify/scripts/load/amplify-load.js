// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// k6 scenario (plan M11): One WSO2 read paths against amplify-api with 1k employees / 50k ledger rows.
// Each endpoint gets its own constant-arrival-rate scenario so its p95 is measured on its own; the
// thresholds are the phase 1 target (p95 < 50 ms). Tokens come from TOKENS (JSON array of dev JWTs).
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://amplify-api:9090';
const TOKENS = JSON.parse(open('/scripts/tokens.json'));
const PO_TOKEN = TOKENS[0];
const RATE = parseInt(__ENV.RATE || '50', 10);
const DURATION = __ENV.DURATION || '60s';

function scenario(exec, startTime) {
  return { executor: 'constant-arrival-rate', exec, rate: RATE, timeUnit: '1s', duration: DURATION,
    preAllocatedVUs: 20, maxVUs: 100, startTime };
}

export const options = {
  discardResponseBodies: true,
  scenarios: {
    leaderboard: scenario('leaderboard', '0s'),
    mePoints: scenario('mePoints', '0s'),
    team: scenario('team', '0s'),
  },
  thresholds: {
    'http_req_duration{endpoint:leaderboard}': ['p(95)<50'],
    'http_req_duration{endpoint:me_points}': ['p(95)<50'],
    'http_req_duration{endpoint:team}': ['p(95)<50'],
    'checks': ['rate>0.99'],
    // k6 drops scheduled iterations when it runs out of VUs; the duration thresholds above only see requests that ran.
    'dropped_iterations': ['count==0'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

function token() {
  return TOKENS[1 + Math.floor(Math.random() * (TOKENS.length - 1))];
}

function get(path, tok, endpoint) {
  const res = http.get(`${BASE}${path}`, { headers: { 'x-jwt-assertion': tok }, tags: { endpoint } });
  check(res, { [`${endpoint} 200`]: (r) => r.status === 200 });
}

export function leaderboard() { get('/leaderboard', token(), 'leaderboard'); }
export function mePoints() { get('/me/points', token(), 'me_points'); }
// PO company view, default page size (25, what One WSO2 asks for), random page over 1,000 people.
export function team() {
  const page = Math.floor(Math.random() * 40);
  get(`/team?page=${page}`, PO_TOKEN, 'team');
}
