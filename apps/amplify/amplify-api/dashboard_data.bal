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


// What the dashboards read from the database (ADR-036): one snapshot of every aggregate, taken in one
// transaction and kept for 60 seconds, plus two small per-request reads. Each loader is a test seam.

import amplify_common.resilience;
import amplify_domain.reporting;

import ballerina/time;
import ballerinax/postgresql;

# Everything the five boards need, as of one moment (read by `reporting:loadSnapshot`).
type Snapshot reporting:Snapshot;

# How long a snapshot is reused, seconds.
const decimal SNAPSHOT_SECONDS = 60;

isolated [Snapshot & readonly, decimal]? snapshotCache = ();

# The snapshot: cached for 60 seconds, so a refresh storm costs one set of queries.
#
# + return - The snapshot, or an error
isolated function snapshot() returns Snapshot & readonly|error {
    decimal mono = time:monotonicNow();
    lock {
        [Snapshot & readonly, decimal]? hit = snapshotCache;
        if hit is [Snapshot & readonly, decimal] && mono - hit[1] < SNAPSHOT_SECONDS {
            return hit[0];
        }
    }
    Snapshot & readonly fresh = (check loadSnapshot(time:utcNow())).cloneReadOnly();
    lock {
        snapshotCache = [fresh, mono];
    }
    return fresh;
}

# Number of cached snapshots (0 or 1), a test seam.
#
# + return - 1 when a snapshot is cached
isolated function snapshotCacheSize() returns int {
    lock {
        return snapshotCache is () ? 0 : 1;
    }
}

# Reads the snapshot from the database (a test seam): one repeatable-read, read-only transaction in
# `reporting:loadSnapshot`. Not wrapped in the transient retry the per-request reads use: it runs a
# `transaction`, and ADR-032 keeps a transaction out of a `retry` (a retried block races the one gate).
#
# + now - Current time
# + return - The snapshot, or an error
isolated function loadSnapshot(time:Utc now) returns Snapshot|error => reporting:loadSnapshot(check db(), now);

# Reposts by category since a time (a per-request read, not in the snapshot: `days` varies).
#
# + since - Window start
# + return - Categories, or an error
isolated function categoryCounts(time:Utc since) returns reporting:CategoryCount[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        postgresql:Client pg = check db();
        return reporting:repostsByCategory(pg, since);
    }
}

# One campaign's reposts by day since it opened, the first seven days.
#
# + campaignId - Campaign
# + return - Seven counts, or an error
isolated function campaignByDay(string campaignId) returns int[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        postgresql:Client pg = check db();
        return reporting:repostsByDay(pg, campaignId, 7);
    }
}

# One campaign's card and everyone who reposted it, for the Post Performance popup.
#
# + campaignId - Campaign
# + return - Card and people, or an error
isolated function campaignPeople(string campaignId) returns [reporting:CampaignCard, reporting:Reposter[]]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        postgresql:Client pg = check db();
        reporting:CampaignCard card = (check reporting:campaignCard(pg, campaignId)) ?: {summary: (), imageUrl: (), resourceUrl: (), resourceUrn: ""};
        return [card, check reporting:campaignReposters(pg, campaignId)];
    }
}

# The raw rows behind the boards for a date range (the Participation export).
#
# + 'from - First moment
# + to - First moment not included
# + return - Rows, or an error
isolated function exportRows(time:Utc 'from, time:Utc to) returns reporting:ExportRow[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        postgresql:Client pg = check db();
        return reporting:exportRows(pg, 'from, to);
    }
}

# One person and the posts they reposted, for the person popup.
#
# + employeeId - Employee id
# + return - The person, their posts and the points they earned this month, `()` when Amplify has never seen the id, or an error
isolated function personPosts(string employeeId) returns [reporting:PersonIdentity, reporting:PersonPost[], int]?|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        postgresql:Client pg = check db();
        reporting:PersonIdentity? who = check reporting:personIdentity(pg, employeeId);
        if who is () {
            return ();
        }
        return [who, check reporting:personPosts(pg, employeeId), check reporting:personPointsThisMonth(pg, employeeId)];
    }
}
