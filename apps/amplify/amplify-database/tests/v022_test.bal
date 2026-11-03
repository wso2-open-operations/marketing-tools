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

// V022: announcement.attempted_at, the Novera attempt marker. Nullable, and the recreated view carries it next to
// the derived status.

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV022AnnouncementAttemptedAt() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V022__announcement_attempted_at'`);
    test:assertEquals(applied, 1);

    _ = check jobs->execute(`INSERT INTO announcement (campaign_id, outbox_id, space, thread_key)
                             VALUES ('0192f0e0-0000-7000-8000-000000000022', 22, 'novera', 'amplify:v022')`);
    string? before = check jobs->queryRow(`SELECT attempted_at::text FROM announcement_v
                                           WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000022'`);
    test:assertEquals(before, (), "a new row carries no marker");
    _ = check jobs->execute(`UPDATE announcement SET attempted_at = now()
                             WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000022'`);
    record {|string status; boolean marked;|} row = check jobs->queryRow(`
        SELECT status, attempted_at IS NOT NULL AS marked FROM announcement_v
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000022'`);
    test:assertEquals(row, {status: "QUEUED", marked: true}, "the marker is not a status");
    check admin.close();
    check jobs.close();
}
