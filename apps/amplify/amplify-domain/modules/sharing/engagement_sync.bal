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

// The Community Management engagement sync (phase 4): reactions, comments and native reshares on the page's open
// campaign posts become `Engagement` facts (`COMMUNITY_MANAGEMENT`, `API_SYNC`) with their `EngagementRecorded`
// event, so the existing scoring awards the points. Two ports keep the rules here free of HTTP and SQL:
// `EngagementSource` (what LinkedIn says, adapted by amplify-jobs) and `SyncStore` (campaigns, member matching,
// cursors, the call budget and the writes; amplify-jobs composes it from the campaign, connection and sharing
// modules, each on its own tables).

import amplify_common.types;

import ballerina/lang.'int as ints;
import ballerina/time;

# Reactions on a post.
public const REACTIONS = "REACTIONS";
# Comments on a post.
public const COMMENTS = "COMMENTS";
# Reshares of the page's posts.
public const SHARE_NOTIFICATIONS = "SHARE_NOTIFICATIONS";

# Which LinkedIn finder a cursor belongs to (`sharing_sync_cursor.endpoint`).
public type SyncEndpoint REACTIONS|COMMENTS|SHARE_NOTIFICATIONS;

# What LinkedIn reported.
public type ObservedKind "REACTION"|"COMMENT"|"RESHARE";

# One item LinkedIn reported, in domain terms (the adapter maps the wire shapes).
public type Observed record {|
    # Reaction, comment or reshare
    ObservedKind kind;
    # Who did it: a member URN, or an organization (never matched)
    string actorUrn;
    # The post acted on (a reshare's source post)
    string targetUrn;
    # Comment URN or reshare URN; `()` for a reaction (its id embeds the member URN, so it isn't kept)
    string? activityUrn = ();
    # A reshare with the member's own words
    boolean hasCommentary = false;
    # When it happened
    time:Utc occurredAt;
|};

# One page from the source. `fetched` counts every element returned, so an offset cursor moves by it.
public type ObservedPage record {|
    # Usable items
    Observed[] items;
    # Elements returned
    int fetched;
|};

# Why the source stopped the sync. The cursors stay where they are; the next run carries on.
public type SourceStop "RATE_LIMITED"|"UNAVAILABLE"|"UNAUTHORIZED"|"REJECTED";

# Detail of a source failure.
public type SourceErrorDetail record {|
    # Why
    SourceStop reason;
|};

# A source call failed.
public type SourceError distinct error<SourceErrorDetail>;

# The page's engagement on LinkedIn, read with the page token (amplify-jobs adapts `linkedin:CommunityPort`).
public type EngagementSource isolated object {
    # Reactions on a post, oldest first.
    #
    # + targetUrn - Post
    # + 'start - Offset
    # + count - Page size
    # + return - The page, or why the sync must stop
    public isolated function reactions(string targetUrn, int 'start, int count) returns ObservedPage|SourceError;

    # Comments on a post, oldest first.
    #
    # + targetUrn - Post
    # + 'start - Offset
    # + count - Page size
    # + return - The page, or why the sync must stop
    public isolated function comments(string targetUrn, int 'start, int count) returns ObservedPage|SourceError;

    # Reshares of the page's posts in a time range.
    #
    # + startMs - Range start, epoch milliseconds
    # + endMs - Range end, epoch milliseconds
    # + 'start - Offset
    # + count - Page size
    # + return - The page, or why the sync must stop
    public isolated function reshares(int startMs, int endMs, int 'start, int count) returns ObservedPage|SourceError;
};

# A campaign the sync reads (open, the page's).
public type SyncCampaign record {|
    # Campaign id
    string id;
    # The page post
    string resourceUrn;
    # Window start: engagement before it doesn't count
    time:Utc opensAt;
    # Window end
    time:Utc closesAt;
|};

# What the sync reads and writes. Each method stays on its own context's tables.
public type SyncStore isolated object {
    # The page's open campaigns (campaign).
    #
    # + now - Current time
    # + return - Campaigns, or an error
    public isolated function openCampaigns(time:Utc now) returns SyncCampaign[]|error;

    # Employees connected with these member URNs (connection).
    #
    # + memberUrns - Member URNs
    # + return - Member URN -> employee id, or an error
    public isolated function employeesOf(string[] memberUrns) returns map<types:EmployeeId>|error;

    # A cursor (sharing).
    #
    # + resourceUrn - Post or page
    # + endpoint - Finder
    # + return - The cursor, `()` before the first run, or an error
    public isolated function cursor(string resourceUrn, SyncEndpoint endpoint) returns string|error?;

    # Moves a cursor (sharing).
    #
    # + resourceUrn - Post or page
    # + endpoint - Finder
    # + cursor - New value
    # + now - Run time
    # + return - An error on failure
    public isolated function saveCursor(string resourceUrn, SyncEndpoint endpoint, string cursor, time:Utc now)
        returns error?;

    # Counts one Community Management call against today's budget (sharing).
    #
    # + now - Current time (its UTC day)
    # + budget - `engagement.daily_call_budget`
    # + return - False when the budget is spent (nothing counted), or an error
    public isolated function takeCall(time:Utc now, int budget) returns boolean|error;

    # Records a synced engagement with its `EngagementRecorded` event in one transaction, and for a reshare marks
    # the employee's native intent detected (sharing).
    #
    # + engagement - From `syncedEngagement`
    # + now - Current time
    # + return - True when recorded; false when an engagement already covers it (the unique keys, or for a reshare
    # a share of that post the employee already has), or an error
    public isolated function recordSynced(Engagement engagement, time:Utc now) returns boolean|error;
};

# How a run behaves.
public type SyncSettings record {|
    # The page whose token the source uses (the share-notification cursor is kept per page)
    string pageUrn;
    # `engagement.daily_call_budget`
    int dailyBudget;
    # Elements per call
    int pageSize = 50;
    # Most pages per post and finder in one run, so one busy post can't take the whole budget
    int maxPagesPerFinder = 10;
    # Share notifications are read again from this long before the last run's end (late notifications), seconds
    int notificationOverlapSeconds = 3600;
    # The first run reads share notifications back to the oldest open campaign, at most this long, seconds
    int firstLookbackSeconds = 2592000;
|};

# How a run ended.
public type SyncStatus "DONE"|"BUDGET_REACHED"|SourceStop;

# What a run did.
public type SyncReport record {|
    # How it ended
    SyncStatus status;
    # Open campaigns read
    int campaigns = 0;
    # Calls made
    int calls = 0;
    # New `REACTION` engagements
    int reactions = 0;
    # New `COMMENT` engagements
    int comments = 0;
    # New `REPOST` / `REPOST_COMMENTARY` engagements
    int reposts = 0;
    # Items already recorded, or reshares of a post the employee already shared
    int alreadyRecorded = 0;
    # Items whose actor is no connected employee (or not a member), or outside the campaign window: dropped
    int dropped = 0;
|};

// ---- Rules (pure) ---------------------------------------------------------------------------------

# The engagement fact for a synced item.
#
# + observed - The item
# + campaign - Its campaign
# + memberUrn - The actor, a member URN
# + employeeId - The employee connected with it
# + id - New UUIDv7
# + now - Current time
# + return - The fact (`COMMUNITY_MANAGEMENT`, `API_SYNC`)
public isolated function syncedEngagement(Observed observed, SyncCampaign campaign, types:MemberUrn memberUrn,
        types:EmployeeId employeeId, string id, time:Utc now) returns Engagement => {
    id,
    provider: types:LINKEDIN,
    providerApi: types:COMMUNITY_MANAGEMENT,
    origin: types:API_SYNC,
    targetResourceUrn: campaign.resourceUrn,
    campaignId: campaign.id,
    actorMemberUrn: memberUrn,
    employeeId,
    action: syncedAction(observed),
    activityUrn: observed.kind == "REACTION" ? () : observed.activityUrn,
    occurredAt: observed.occurredAt,
    observedAt: now,
    lastVerifiedAt: (),
    deletedAt: ()
};

# The action a synced item records: a reshare with words is `REPOST_COMMENTARY`, without `REPOST`.
#
# + observed - The item
# + return - The action
public isolated function syncedAction(Observed observed) returns types:EngagementAction {
    match observed.kind {
        "REACTION" => {
            return types:REACTION;
        }
        "COMMENT" => {
            return types:COMMENT;
        }
    }
    return observed.hasCommentary ? types:REPOST_COMMENTARY : types:REPOST;
}

# Whether an item falls inside its campaign's window.
#
# + observed - The item
# + campaign - Its campaign
# + return - True from `opensAt` to `closesAt`
public isolated function inWindow(Observed observed, SyncCampaign campaign) returns boolean =>
    time:utcDiffSeconds(observed.occurredAt, campaign.opensAt) >= 0d
        && time:utcDiffSeconds(campaign.closesAt, observed.occurredAt) > 0d;

# Epoch milliseconds of a time.
#
# + t - Time
# + return - Milliseconds
public isolated function epochMillis(time:Utc t) returns int => t[0] * 1000 + <int>(t[1] * 1000d);

# A time from epoch milliseconds.
#
# + ms - Milliseconds
# + return - Time
public isolated function fromEpochMillis(int ms) returns time:Utc => [ms / 1000, <decimal>(ms % 1000) / 1000d];

// ---- Use case -------------------------------------------------------------------------------------

# One sync run: for each open campaign, reactions then comments from their cursors; then the share notifications
# since the last run. Every call is counted against the day's budget first. A rate limit, an open breaker or a
# refused token stops the run with the cursors where they are; replays are harmless (the engagement unique keys).
#
# + linkedIn - LinkedIn, with the page token
# + store - Campaigns, members, cursors, budget, writes
# + settings - Budget and page sizes
# + now - Run time
# + return - What was done, or a store error
public isolated function syncEngagement(EngagementSource linkedIn, SyncStore store, SyncSettings settings, time:Utc now)
        returns SyncReport|error {
    SyncReport report = {status: "DONE"};
    SyncCampaign[] campaigns = check store.openCampaigns(now);
    report.campaigns = campaigns.length();
    if campaigns.length() == 0 {
        return report;
    }
    foreach SyncCampaign c in campaigns {
        foreach SyncEndpoint endpoint in <SyncEndpoint[]>[REACTIONS, COMMENTS] {
            SyncStatus? stop = check syncPost(linkedIn, store, settings, c, endpoint, now, report);
            if stop is SyncStatus {
                report.status = stop;
                return report;
            }
        }
    }
    SyncStatus? stop = check syncReshares(linkedIn, store, settings, campaigns, now, report);
    if stop is SyncStatus {
        report.status = stop;
    }
    return report;
}

isolated function syncPost(EngagementSource linkedIn, SyncStore store, SyncSettings settings, SyncCampaign c,
        SyncEndpoint endpoint, time:Utc now, SyncReport report) returns SyncStatus?|error {
    string? saved = check store.cursor(c.resourceUrn, endpoint);
    int offset = offsetOf(saved);
    foreach int _ in 0 ..< settings.maxPagesPerFinder {
        if !check store.takeCall(now, settings.dailyBudget) {
            return "BUDGET_REACHED";
        }
        report.calls += 1;
        ObservedPage|SourceError page = endpoint == REACTIONS
            ? linkedIn.reactions(c.resourceUrn, offset, settings.pageSize)
            : linkedIn.comments(c.resourceUrn, offset, settings.pageSize);
        if page is SourceError {
            return page.detail().reason;
        }
        check recordAll(store, page.items, [c], now, report);
        if page.fetched > 0 {
            offset += page.fetched;
            check store.saveCursor(c.resourceUrn, endpoint, offset.toString(), now);
        }
        if page.fetched < settings.pageSize {
            return ();
        }
    }
    return ();
}

isolated function syncReshares(EngagementSource linkedIn, SyncStore store, SyncSettings settings,
        SyncCampaign[] campaigns, time:Utc now, SyncReport report) returns SyncStatus?|error {
    string pageKey = settings.pageUrn;
    string? saved = check store.cursor(pageKey, SHARE_NOTIFICATIONS);
    int endMs = epochMillis(now);
    int startMs;
    int|error last = saved is string ? ints:fromString(saved) : error("no cursor");
    if last is int {
        startMs = last - settings.notificationOverlapSeconds * 1000;
    } else {
        int oldest = endMs;
        foreach SyncCampaign c in campaigns {
            int opens = epochMillis(c.opensAt);
            oldest = opens < oldest ? opens : oldest;
        }
        int floor = endMs - settings.firstLookbackSeconds * 1000;
        startMs = oldest < floor ? floor : oldest;
    }
    int offset = 0;
    foreach int _ in 0 ..< settings.maxPagesPerFinder {
        if !check store.takeCall(now, settings.dailyBudget) {
            return "BUDGET_REACHED";
        }
        report.calls += 1;
        ObservedPage|SourceError page = linkedIn.reshares(startMs, endMs, offset, settings.pageSize);
        if page is SourceError {
            return page.detail().reason;
        }
        check recordAll(store, page.items, campaigns, now, report);
        offset += page.fetched;
        if page.fetched < settings.pageSize {
            break;
        }
    }
    // Moved only once the window was read (or the page limit reached): a stop above keeps the old one.
    check store.saveCursor(pageKey, SHARE_NOTIFICATIONS, endMs.toString(), now);
    return ();
}

isolated function recordAll(SyncStore store, Observed[] items, SyncCampaign[] campaigns, time:Utc now,
        SyncReport report) returns error? {
    string[] members = [];
    foreach Observed o in items {
        if types:parseMemberUrn(o.actorUrn) is types:MemberUrn && members.indexOf(o.actorUrn) is () {
            members.push(o.actorUrn);
        }
    }
    map<types:EmployeeId> employees = check store.employeesOf(members);
    foreach Observed o in items {
        SyncCampaign? c = campaignOf(o, campaigns);
        types:EmployeeId? employeeId = employees[o.actorUrn];
        if c is () || employeeId is () || !inWindow(o, c) {
            report.dropped += 1;
            continue;
        }
        Engagement e = syncedEngagement(o, c, o.actorUrn, employeeId, types:newUuidV7(), now);
        if !check store.recordSynced(e, now) {
            report.alreadyRecorded += 1;
            continue;
        }
        match e.action {
            types:REACTION => {
                report.reactions += 1;
            }
            types:COMMENT => {
                report.comments += 1;
            }
            _ => {
                report.reposts += 1;
            }
        }
    }
}

isolated function campaignOf(Observed o, SyncCampaign[] campaigns) returns SyncCampaign? {
    if campaigns.length() == 1 && o.kind != "RESHARE" {
        return campaigns[0];
    }
    foreach SyncCampaign c in campaigns {
        if c.resourceUrn == o.targetUrn {
            return c;
        }
    }
    return ();
}

isolated function offsetOf(string? cursor) returns int {
    if cursor is () {
        return 0;
    }
    int|error n = ints:fromString(cursor);
    return n is int && n > 0 ? n : 0;
}
