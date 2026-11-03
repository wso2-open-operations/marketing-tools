#!/bin/sh
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

# Local stand-in for what the DBA does in staging and production: one login user, a schema named after it, and the
# extensions. There are no roles (ADR-043): the login owns everything and every component connects as it. Idempotent.
# Postgres runs it on a fresh volume (docker-entrypoint-initdb.d); `make dba-setup` runs it on an existing one.
# Needs AMPLIFY_DB_USER and AMPLIFY_DB_PASSWORD; POSTGRES_USER and POSTGRES_DB come from the postgres image.
set -eu
: "${AMPLIFY_DB_USER:?}" "${AMPLIFY_DB_PASSWORD:?}"
psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-amplify}" \
  -v dbuser="$AMPLIFY_DB_USER" -v dbpass="$AMPLIFY_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dbuser') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'dbuser', :'dbpass') \gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'dbuser', :'dbuser') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'dbuser') \gexec
-- Local convenience only: psql sessions (e2e, unlink and load scripts) find the tables without naming the schema.
-- The services don't rely on it; they set the search_path themselves.
SELECT format('ALTER DATABASE %I SET search_path TO %I, public', current_database(), :'dbuser') \gexec
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
SQL
