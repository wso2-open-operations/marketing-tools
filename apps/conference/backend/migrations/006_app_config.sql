-- Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

-- Named app_config (not the old bare `config`) to match the Go-side naming
-- (AppConfig type, /app-configs route) and avoid reading as a collision with
-- this service's own internal/config package -- a naming clarity choice,
-- not a functional one. No write route exists through this API, exactly
-- like the old service -- population is direct-SQL-seed only (see
-- .claude/PLAN.md).
CREATE TABLE app_config (
  config_key  TEXT PRIMARY KEY,
  value       TEXT,
  created_by  TEXT NOT NULL,
  updated_by  TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
