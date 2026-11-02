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

-- V020: a person whose Asgardeo account was re-created signs in with a new `sub` and the same email. Until now that was
-- a unique violation on identity.employee.email, answered 409 forever. The employee id keys the points ledger, the
-- standings, connections, shares and the audit log; those are history and are never rewritten, so the new `sub` is
-- mapped to the person's first employee id instead (an alias) and everything keeps one key. Nothing else changes.
--
-- One row per alias `sub`. The first sign-in of the new account creates it (amplify-api, once, with an audit row
-- `EMPLOYEE_ALIASED`); it holds two opaque ids and no email or name.

SET LOCAL ROLE amplify_migrate;

CREATE TABLE identity.employee_alias (
    alias_sub   text        PRIMARY KEY CHECK (length(alias_sub) BETWEEN 1 AND 255),
    employee_id text        NOT NULL CHECK (length(employee_id) BETWEEN 1 AND 255),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT employee_alias_not_self_ck CHECK (employee_id <> alias_sub)
);
CREATE INDEX employee_alias_employee_idx ON identity.employee_alias (employee_id);

COMMENT ON TABLE identity.employee_alias IS
    'A re-created Asgardeo account (new sub, same email) mapped to the employee id the person already has.';

GRANT SELECT, INSERT ON identity.employee_alias TO amplify_api;
GRANT SELECT ON identity.employee_alias TO amplify_jobs, amplify_readonly;
