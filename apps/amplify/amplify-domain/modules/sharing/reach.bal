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


// Post reach (#1781): the impressions and members reached of the employees' own in-app shares, read with each
// employee's Reach token and kept as the latest value per post per UTC day (`sharing_engagement_metric`). The rules
// live here; amplify-jobs adapts the LinkedIn analytics port and the Reach tokens to `ReachReader`. Calls count against
// the same daily Community Management budget as the engagement sync (`sharing_api_usage`), two per post.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Calls one reading takes (impressions, members reached).
public const int CALLS_PER_READING = 2;

# An in-app share to measure: the employee's own post.
public type ReachTarget record {|
    # `sharing_engagement.id`
    string engagementId;
    # The employee who shared
    types:EmployeeId employeeId;
    # Their post (`activity_urn`)
    string postUrn;
|};

# One reading.
public type ReachReading record {|
    # Times the post was shown
    int impressions;
    # Unique members it reached
    int membersReached;
|};

# Why one post or employee is skipped without stopping the run: `NO_TOKEN` (the employee's Reach connection can't be
# used: expired, refused, undecryptable), `NOT_READABLE` (LinkedIn refused this post: deleted, or not the member's).
public type ReachSkip "NO_TOKEN"|"NOT_READABLE";

# Reads one post's metrics with the employee's Reach token (amplify-jobs adapts LinkedIn).
public type ReachReader isolated object {
    # Reads a post's lifetime impressions and members reached.
    #
    # + target - The share
    # + return - The reading, a skip, or a `SourceError` that stops the run (rate limit, LinkedIn down)
    public isolated function read(ReachTarget target) returns ReachReading|ReachSkip|SourceError;
};

# What the refresh needs from the database.
public type ReachStore isolated object {
    # In-app shares since a time by employees with a Reach connection, not yet measured on `today`, oldest first.
    #
    # + since - Window start
    # + today - UTC day, `YYYY-MM-DD`
    # + return - Targets, or an error
    public isolated function targets(time:Utc since, string today) returns ReachTarget[]|error;

    # Counts one call against the UTC day's budget.
    #
    # + now - Current time
    # + budget - Calls per UTC day
    # + return - False when the budget is spent, or an error
    public isolated function takeCall(time:Utc now, int budget) returns boolean|error;

    # Stores a reading (replaces the day's earlier one).
    #
    # + target - The share
    # + reading - The reading
    # + now - Current time (sets the day)
    # + return - An error on failure
    public isolated function saveReading(ReachTarget target, ReachReading reading, time:Utc now) returns error?;
};

# Refresh settings.
public type ReachOptions record {|
    # Shares of the last N days
    int windowDays = 30;
    # Calls per UTC day, shared with the engagement sync
    int dailyBudget = 450;
    # Most posts in one run
    int maxPosts = 500;
|};

# How a refresh ended.
public type ReachRunStatus "DONE"|"BUDGET_REACHED"|"POST_LIMIT"|SourceStop;

# What a refresh did.
public type ReachReport record {|
    # How it ended
    ReachRunStatus status;
    # Shares in the window waiting for today's reading
    int targets;
    # Readings stored
    int measured;
    # Posts skipped because the employee's Reach token couldn't be used
    int skippedNoToken;
    # Posts LinkedIn wouldn't read (deleted, not the member's)
    int skippedNotReadable;
    # Calls counted against the budget
    int calls;
|};

# Reads the reach of the window's in-app shares, within the daily budget. A skip never stops the run; a rate limit
# or an outage does, and the next run carries on (only posts without today's reading are read).
#
# + st - Database side
# + reader - LinkedIn side
# + options - Window, budget, cap
# + now - Run time
# + return - The report, or a database error
public isolated function refreshReach(ReachStore st, ReachReader reader, ReachOptions options, time:Utc now)
        returns ReachReport|error {
    string today = time:utcToString(now).substring(0, 10);
    time:Utc since = time:utcAddSeconds(now, -86400d * <decimal>options.windowDays);
    ReachTarget[] targets = check st.targets(since, today);
    ReachReport report = {status: "DONE", targets: targets.length(), measured: 0, skippedNoToken: 0,
        skippedNotReadable: 0, calls: 0};
    map<boolean> noToken = {};
    foreach ReachTarget t in targets {
        if noToken.hasKey(t.employeeId) {
            report.skippedNoToken += 1;
            continue;
        }
        if report.measured + report.skippedNotReadable >= options.maxPosts {
            report.status = "POST_LIMIT";
            return report;
        }
        foreach int _ in 0 ..< CALLS_PER_READING {
            if !check st.takeCall(now, options.dailyBudget) {
                report.status = "BUDGET_REACHED";
                return report;
            }
            report.calls += 1;
        }
        ReachReading|ReachSkip|SourceError reading = reader.read(t);
        if reading is SourceError {
            SourceStop reason = reading.detail().reason;
            if reason == "RATE_LIMITED" || reason == "UNAVAILABLE" {
                report.status = reason;
                return report;
            }
            // A refused token or post is the employee's, not the run's.
            reading = reason == "UNAUTHORIZED" ? "NO_TOKEN" : "NOT_READABLE";
        }
        if reading is ReachReading {
            check st.saveReading(t, reading, now);
            report.measured += 1;
        } else if reading == "NO_TOKEN" {
            noToken[t.employeeId] = true;
            report.skippedNoToken += 1;
        } else {
            report.skippedNotReadable += 1;
        }
    }
    return report;
}

// ---- PostgreSQL (sharing tables only) ---------------------------------------------------------------

# The reach refresh's reads and writes on the sharing tables.
public isolated class PgReachRepository {

    private final postgresql:Client db;

    # + db - Shared client
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    # In-app shares (repost kinds, not deleted, with the employee's post URN) since a time by these employees, without
    # a reading on `today`, oldest first.
    #
    # + employeeIds - Employees with a Reach connection
    # + since - Window start
    # + today - UTC day, `YYYY-MM-DD`
    # + return - Targets, or an error
    public isolated function sharesToMeasure(types:EmployeeId[] employeeIds, time:Utc since, string today)
            returns ReachTarget[]|error {
        if employeeIds.length() == 0 {
            return [];
        }
        string ids = store:arrayLiteral(employeeIds);
        stream<record {|string id; string employee_id; string activity_urn;|}, error?> rows = self.db->query(`
            SELECT e.id::text AS id, e.employee_id, e.activity_urn
            FROM sharing_engagement e
            WHERE e.origin = 'IN_APP' AND e.deleted_at IS NULL AND e.activity_urn IS NOT NULL
              AND e.action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY')
              AND e.occurred_at >= CAST(${store:ts(since)} AS timestamptz)
              AND e.employee_id = ANY(CAST(${ids} AS text[]))
              AND NOT EXISTS (SELECT 1 FROM sharing_engagement_metric m
                              WHERE m.engagement_id = e.id AND m.captured_on = CAST(${today} AS date))
            ORDER BY e.occurred_at, e.id`);
        return from var r in rows
            select {engagementId: r.id, employeeId: r.employee_id, postUrn: r.activity_urn};
    }

    # Stores a reading: the latest value per post per UTC day.
    #
    # + target - The share
    # + reading - The reading
    # + now - Current time
    # + return - An error on failure
    public isolated function saveReading(ReachTarget target, ReachReading reading, time:Utc now) returns error? {
        string day = time:utcToString(now).substring(0, 10);
        _ = check self.db->execute(`
            INSERT INTO sharing_engagement_metric (engagement_id, captured_on, provider_api, post_urn, impressions,
                                                   members_reached, fetched_at)
            VALUES (CAST(${target.engagementId} AS uuid), CAST(${day} AS date), ${types:COMMUNITY_MANAGEMENT},
                    ${target.postUrn}, ${reading.impressions}, ${reading.membersReached},
                    CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (engagement_id, captured_on)
            DO UPDATE SET impressions = EXCLUDED.impressions, members_reached = EXCLUDED.members_reached,
                          post_urn = EXCLUDED.post_urn, fetched_at = EXCLUDED.fetched_at`);
    }
}
