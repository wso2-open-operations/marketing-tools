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

-- V017: least privilege on the token table (security review). The API and the worker each only need part of what
-- V003 granted them on connection.provider_token:
--   amplify_api  connects and removes a connection: INSERT, SELECT (to revoke at LinkedIn first), DELETE. It never
--                rewrites a token row, so UPDATE goes.
--   amplify_jobs reads tokens to publish, re-seals them under a new key and deletes expired ones: SELECT, UPDATE,
--                DELETE. It never creates one (only a sign-in does), so INSERT goes.
-- Reading is still needed on both sides (the API revokes at LinkedIn when a person removes their connection), so a
-- compromised API process can still read ciphertext; the keys stay in the process. Moving the revoke into the worker
-- would remove the API's SELECT as well.

SET LOCAL ROLE amplify_migrate;

REVOKE UPDATE ON connection.provider_token FROM amplify_api;
REVOKE INSERT ON connection.provider_token FROM amplify_jobs;
