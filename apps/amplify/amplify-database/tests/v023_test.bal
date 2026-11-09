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

// V023: the Novera broadcast id and seen count on announcement. All nullable, checked, and carried by the recreated
// view next to the derived status.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV023AnnouncementNoveraSeen() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V023__announcement_novera_seen'`);
    test:assertEquals(applied, 1);

    _ = check jobs->execute(`INSERT INTO announcement (campaign_id, outbox_id, space, thread_key, sent_at)
                             VALUES ('0192f0e0-0000-7000-8000-000000000023', 23, 'novera', 'amplify:v023', now())`);
    record {|string? novera_notification_id; int? novera_seen;|} fresh = check jobs->queryRow(`
        SELECT novera_notification_id, novera_seen FROM announcement_v
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    test:assertEquals(fresh, {novera_notification_id: (), novera_seen: ()}, "a row starts with no id and no count");

    _ = check jobs->execute(`UPDATE announcement
                             SET novera_notification_id = '0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21',
                                 novera_recipients = 900, novera_seen = 312, novera_checked_at = now()
                             WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    record {|string status; int? novera_recipients; int? novera_seen; boolean checked;|} counted = check jobs->queryRow(`
        SELECT status, novera_recipients, novera_seen, novera_checked_at IS NOT NULL AS checked FROM announcement_v
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    test:assertEquals(counted, {status: "SENT", novera_recipients: 900, novera_seen: 312, checked: true});

    // More seen than recipients, a negative count, or an id that isn't URL-safe are refused.
    sql:ExecutionResult|sql:Error tooMany = jobs->execute(`UPDATE announcement SET novera_seen = 901
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    test:assertTrue(tooMany is sql:Error, "seen never above recipients");
    sql:ExecutionResult|sql:Error negative = jobs->execute(`UPDATE announcement SET novera_recipients = -1
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    test:assertTrue(negative is sql:Error, "no negative count");
    sql:ExecutionResult|sql:Error unsafe = jobs->execute(`UPDATE announcement SET novera_notification_id = 'a/b'
        WHERE campaign_id = '0192f0e0-0000-7000-8000-000000000023'`);
    test:assertTrue(unsafe is sql:Error, "the id must be URL-safe");
    check admin.close();
    check jobs.close();
}
