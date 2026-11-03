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

-- V001: the schema, the extensions and uuidv7() on servers older than PostgreSQL 18 (phase1-data-model, B18, ADR-044).
--
-- The database gives Amplify one login user and one schema named after it (staging `amplify_stg_user`,
-- production its own name). There are no roles: the login user owns every object and every component connects
-- as it (ADR-043). This script creates no schema and no role; it checks that the schema exists, that the two
-- extensions are installed, and that `uuidv7()` exists (V002-V008 use it as a column default).
--
-- The runner connects as the login user and puts the schema first on the `search_path` (`dbSchema`, default the
-- user name), so no script names a schema and every table is `<context>_<name>`. `SECURITY DEFINER` functions
-- use `SET search_path FROM CURRENT`, which captures that list.

DO $check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'No schema on the search_path: create the schema named after the login user (%) or set dbSchema',
            current_user;
    END IF;
END
$check$;

-- Required extensions (B18). Both are trusted, so they work on managed Postgres without superuser; when the DBA
-- already installed them this does nothing.
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- uuidv7() for PostgreSQL before 18 (ADR-044). PostgreSQL 18 ships a native uuidv7(); earlier servers (staging runs 17)
-- don't, so this script creates one in the current schema when the server has none, and does nothing on 18. It has to
-- be here, in the first script, because V002 and later use it as a column default.
--
-- The function is the usual SQL form: a v4 random uuid whose first 48 bits are replaced by the Unix time in
-- milliseconds and whose version bits are set to 7. It sorts by creation across milliseconds like the native one,
-- but does not add the native sub-millisecond counter, so two ids made in the same millisecond are ordered randomly.
-- Each table binds the function by OID when its default is created, so upgrading the server to 18 later leaves
-- existing tables working. The schema must be first on the `search_path` (the runner does that; by hand, set it).

DO $compat$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname = 'uuidv7' AND p.pronamespace = 'pg_catalog'::regnamespace) THEN
        RAISE NOTICE 'native uuidv7() found; nothing to install';
        RETURN;
    END IF;
    EXECUTE $def$
        CREATE OR REPLACE FUNCTION uuidv7() RETURNS uuid
            LANGUAGE sql VOLATILE PARALLEL SAFE
        AS $body$
            SELECT encode(
                set_bit(
                    set_bit(
                        overlay(uuid_send(gen_random_uuid())
                                PLACING substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
                                FROM 1 FOR 6),
                        52, 1),
                    53, 1),
                'hex')::uuid
        $body$
    $def$;
END
$compat$;
