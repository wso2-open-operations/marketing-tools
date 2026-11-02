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

-- D2 / ADR-002 gate: run once on a real Choreo-managed (Aiven) PostgreSQL database
-- and paste the output into the plan (M0 D2) before starting M3.
-- Required by the data model: citext, pg_trgm. Nice to have: pg_partman, pg_cron, pgaudit.
-- If citext or pg_trgm is missing, change the design before M3 (B18).

SELECT version();

SELECT name,
       default_version,
       installed_version,
       CASE WHEN name IN ('citext', 'pg_trgm') THEN 'REQUIRED' ELSE 'optional' END AS need
FROM pg_available_extensions
WHERE name IN ('pg_partman', 'pg_cron', 'pgaudit', 'citext', 'pg_trgm')
ORDER BY need DESC, name;

-- Anything required that is not listed at all:
SELECT r.name AS missing_required
FROM (VALUES ('citext'), ('pg_trgm')) AS r(name)
LEFT JOIN pg_available_extensions e ON e.name = r.name
WHERE e.name IS NULL;
