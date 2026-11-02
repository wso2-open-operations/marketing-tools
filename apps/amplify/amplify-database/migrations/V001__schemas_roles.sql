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

-- V001: roles, schemas, extensions (phase1-data-model › Database users and grants, B12, B18).
--
-- Runs as the bootstrap admin user (Choreo/Aiven `avnadmin`, local `postgres`), the only script that does.
-- Every later script starts with `SET LOCAL ROLE amplify_migrate`, so amplify_migrate owns every object and
-- app roles never own anything (they can't ALTER or DROP).
--
-- Roles are created NOLOGIN with no password. Passwords are never in a script: the runner sets them after
-- the migrations from its secrets (`apiDbPassword`, `jobsDbPassword`, `readonlyDbPassword`) through
-- `public.amplify_set_login_password`, which quotes with format(%L). A role whose secret is empty stays NOLOGIN.

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amplify_migrate') THEN
        CREATE ROLE amplify_migrate NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amplify_api') THEN
        CREATE ROLE amplify_api NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amplify_jobs') THEN
        CREATE ROLE amplify_jobs NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amplify_readonly') THEN
        CREATE ROLE amplify_readonly NOLOGIN;
    END IF;
END
$roles$;

-- The bootstrap user must be able to SET ROLE amplify_migrate (PG16+ doesn't grant SET to the creator by default).
GRANT amplify_migrate TO CURRENT_USER WITH SET TRUE, INHERIT FALSE;

DO $db$
BEGIN
    EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO amplify_migrate', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO amplify_api, amplify_jobs, amplify_readonly', current_database());
END
$db$;

-- Required extensions (B18). Both are trusted, so they work on managed Postgres without superuser.
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- Nobody creates objects in public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- One schema per bounded context (ADR-005), owned by amplify_migrate.
CREATE SCHEMA IF NOT EXISTS identity AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS campaign AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS connection AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS sharing AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS external_sharing AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS scoring AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS recognition AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS announcement AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS messaging AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION amplify_migrate;
CREATE SCHEMA IF NOT EXISTS config AUTHORIZATION amplify_migrate;

-- Schema USAGE per the grants table. Table grants live with each table (V002-V008).
GRANT USAGE ON SCHEMA identity, campaign, connection, sharing, external_sharing, scoring, recognition,
    announcement, messaging, audit, config TO amplify_api, amplify_jobs;
GRANT USAGE ON SCHEMA identity, campaign, sharing, external_sharing, scoring, recognition, announcement
    TO amplify_readonly;

-- Sets a role's password and LOGIN. Only the four Amplify roles; called by the runner with bind parameters.
CREATE OR REPLACE FUNCTION public.amplify_set_login_password(p_role text, p_password text)
    RETURNS void
    LANGUAGE plpgsql
AS $fn$
BEGIN
    IF p_role NOT IN ('amplify_migrate', 'amplify_api', 'amplify_jobs', 'amplify_readonly') THEN
        RAISE EXCEPTION 'Not an Amplify role: %', p_role;
    END IF;
    IF p_password IS NULL OR length(p_password) < 16 THEN
        RAISE EXCEPTION 'Password for % must be at least 16 characters', p_role;
    END IF;
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', p_role, p_password);
END
$fn$;

REVOKE ALL ON FUNCTION public.amplify_set_login_password(text, text) FROM PUBLIC;
