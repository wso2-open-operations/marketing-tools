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

-- D3: can the single login user run Amplify? Run once per environment, connected as that user (staging
-- `amplify_stg_user`, production its own name). Read-only. Every row should say OK. There are no roles to check
-- (ADR-043): the login owns every object and every component connects as it.

SELECT 'login user' AS item, current_user::text AS value, 'info' AS result
UNION ALL
SELECT 'schema named after the login user exists', current_user::text,
       CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user) THEN 'OK'
            ELSE 'ask the DBA: CREATE SCHEMA ' || current_user || ' AUTHORIZATION ' || current_user END
UNION ALL
SELECT 'login can create objects in that schema', 'CREATE',
       CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user)
                 AND has_schema_privilege(current_user, current_user::text, 'CREATE')
            THEN 'OK' ELSE 'ask the DBA: GRANT USAGE, CREATE ON SCHEMA ' || current_user || ' TO ' || current_user END
UNION ALL
SELECT 'extension ' || e, coalesce((SELECT extversion FROM pg_extension WHERE extname = e), 'not installed'),
       CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = e) THEN 'OK'
            ELSE 'CREATE EXTENSION ' || e || ' (trusted; or ask the DBA)' END
FROM unnest(ARRAY['citext', 'pg_trgm']) AS e
UNION ALL
SELECT 'server version', current_setting('server_version_num'),
       CASE WHEN current_setting('server_version_num')::int >= 150000 THEN 'OK' ELSE 'NEEDS PG 15 or later' END
UNION ALL
SELECT 'uuidv7()', CASE WHEN EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname = 'uuidv7' AND p.pronamespace = 'pg_catalog'::regnamespace)
                        THEN 'native (PostgreSQL 18)' ELSE 'not native' END,
       CASE WHEN current_setting('server_version_num')::int >= 180000 THEN 'OK'
            ELSE 'OK, V001 installs a compatible one in the schema' END;
