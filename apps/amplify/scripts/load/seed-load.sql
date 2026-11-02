-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.

-- Load-test data (plan M11), LOCAL COMPOSE ONLY: 1,000 employees (lt-0001..lt-1000) and 50,000 ledger
-- rows spread over the last six months. Idempotent: rows carry `lt-`/`AMP-lt-` ids and are replaced.
-- Recognition is rebuilt afterwards by amplify-jobs (POST /maintenance/rebuild-recognition).

BEGIN;
DELETE FROM scoring.points_ledger WHERE reference LIKE 'AMP-lt-%';
DELETE FROM identity.employee WHERE employee_id LIKE 'lt-%';

INSERT INTO identity.employee (employee_id, email, display_name, first_seen_at, last_seen_at)
SELECT format('lt-%s', lpad(n::text, 4, '0')), format('lt-%s@example.com', lpad(n::text, 4, '0')),
       format('Load Tester %s', n), now() - interval '200 days', now()
FROM generate_series(1, 1000) AS n;

INSERT INTO scoring.points_ledger (reference, employee_id, campaign_id, source_type, source_id, action, points,
                                   rule_id, actor_id, correlation_id, created_at)
SELECT format('AMP-lt-%s', lpad(n::text, 6, '0')),
       format('lt-%s', lpad((1 + (hashint4(n) & 2147483647) % 1000)::text, 4, '0')),
       uuidv7(), 'ENGAGEMENT', uuidv7(), r.action, r.points, r.id, 'load-seed', 'load-seed',
       now() - make_interval(secs => (hashint4(n * 7) & 2147483647) % (180 * 86400))
FROM generate_series(1, 50000) AS n
CROSS JOIN LATERAL (SELECT id, action, points FROM scoring.point_rule
                    WHERE action = (ARRAY['REPOST', 'REPOST_COMMENTARY', 'SHARE'])[1 + n % 3]
                    ORDER BY effective_from DESC LIMIT 1) AS r;
COMMIT;

ANALYZE identity.employee;
ANALYZE scoring.points_ledger;
SELECT (SELECT count(*) FROM identity.employee WHERE employee_id LIKE 'lt-%') AS employees,
       (SELECT count(*) FROM scoring.points_ledger WHERE reference LIKE 'AMP-lt-%') AS ledger_rows;
