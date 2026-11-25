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

// V025: `recognition_rerank` numbers people 1, 2, 3... with no ties: points, then the earliest last activity (none
// last), then name, then employee id. The gaps count to pass the person ahead.

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV023RerankGivesEveryoneTheirOwnPlace() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V025__company_rank_positions'`);
    test:assertEquals(applied, 1);

    // A scratch period, so the shared `ALL` standings of the other tests are untouched.
    _ = check admin->execute(`
        INSERT INTO recognition_standing (period_key, employee_id, display_name, total_points, last_activity_at)
        VALUES ('V023', 'v023-lead', 'Lead', 100, '2026-11-02T10:00:00Z'),
               ('V023', 'v023-late', 'Aaron Late', 60, '2026-11-02T12:00:00Z'),
               ('V023', 'v023-early', 'Zed Early', 60, '2026-11-02T09:00:00Z'),
               ('V023', 'v023-same-b', 'Zoe Same', 40, '2026-11-02T08:00:00Z'),
               ('V023', 'v023-same-a', 'Abe Same', 40, '2026-11-02T08:00:00Z'),
               ('V023', 'v023-none', 'Nina None', 40, NULL),
               ('V023', 'v023-zero', 'Zero', 0, NULL)`);
    _ = check admin->queryRow(`SELECT recognition_rerank('V023', 3)`, int);

    record {|string employee_id; int rank; int points_to_next_rank; int points_to_top_n;|}[] rows = [];
    stream<record {|string employee_id; int rank; int points_to_next_rank; int points_to_top_n;|}, error?> result =
            admin->query(`SELECT employee_id, rank, points_to_next_rank, points_to_top_n FROM recognition_standing
                          WHERE period_key = 'V023' ORDER BY rank`);
    check from var r in result
        do {
            rows.push(r);
        };
    test:assertEquals(rows.map(r => r.employee_id),
            ["v023-lead", "v023-early", "v023-late", "v023-same-a", "v023-same-b", "v023-none", "v023-zero"],
            "points, earliest first, name next, no time last");
    test:assertEquals(rows.map(r => r.rank), [1, 2, 3, 4, 5, 6, 7], "every place is its own");
    test:assertEquals(rows.map(r => r.points_to_next_rank), [0, 41, 1, 21, 1, 1, 41],
            "points of the person one place ahead, minus your own, plus one");
    test:assertEquals(rows.map(r => r.points_to_top_n), [0, 0, 0, 21, 21, 21, 61],
            "third place has 60: 60 - own + 1");

    _ = check admin->execute(`DELETE FROM recognition_standing WHERE period_key = 'V023'`);
    _ = check admin->execute(`DELETE FROM recognition_standing_version WHERE period_key = 'V023'`);
    check admin.close();
}
