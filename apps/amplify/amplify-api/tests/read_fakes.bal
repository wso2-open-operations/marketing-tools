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

// Fakes for the read seams (database.bal reads, the people directory, LinkedIn OAuth, the token cipher, OAuth
// state, tokens and announcements). The reads honour the DB breaker the way the real ones do: while it isn't
// closed they go through `db()`, so an open breaker still answers 503 (db_breaker_test.bal).

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.recognition;
import amplify_domain.reporting;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;
import ballerina/time;

const string TEST_REDIRECT_URI = "https://one.wso2.test/amplify/linkedin/callback";

# Reads only touch `db()` while the breaker isn't closed, like a real read whose pool is refused.
#
# + return - The breaker's error, or `()`
isolated function dbGate() returns error? {
    if dbBreakerState() != "CLOSED" {
        _ = check db();
    }
}

// ---- People directory (team rosters) ------------------------------------------------------------

# Pretends `peopleDirectoryUrl` is empty (the state before D13 closes).
isolated boolean rosterOff = false;

function setRosterOff(boolean off) {
    lock {
        rosterOff = off;
    }
}

@test:Mock {functionName: "rosterConfigured"}
isolated function mockRosterConfigured() returns boolean {
    lock {
        return !rosterOff;
    }
}

# How the fake directory answers: `ok`, `down` (418, not a breaker status, so the breaker stays closed for
# the other tests) or `garbled` (a body that isn't a directory).
isolated string directoryMode = "ok";
isolated int directoryFetches = 0;

# Sets the fake's answer and drops amplify-api's cached index, so the next read fetches again.
#
# + mode - `ok`, `down` or `garbled`
function setDirectory(string mode) {
    lock {
        directoryMode = mode;
    }
    lock {
        directoryCache = ();
    }
    lock {
        headcountCache = ();
    }
}

function takeDirectoryFetches() returns int {
    lock {
        int n = directoryFetches;
        directoryFetches = 0;
        return n;
    }
}

# Ages the cached index past `rosterCacheSeconds`, as if a day went by.
function expireDirectoryCache() {
    lock {
        [DirectoryIndex & readonly, decimal]? hit = directoryCache;
        if hit is [DirectoryIndex & readonly, decimal] {
            directoryCache = [hit[0], hit[1] - rosterCacheSeconds - 1d];
        }
    }
}

# Ages the cached employee count past `headcountCacheSeconds`, as if a day went by.
function expireHeadcountCache() {
    lock {
        [HeadcountSnapshot & readonly, decimal]? hit = headcountCache;
        if hit is [HeadcountSnapshot & readonly, decimal] {
            headcountCache = [hit[0], hit[1] - headcountCacheSeconds - 1d];
        }
    }
}

final readonly & string[] RIVERS = ["rv-a@wso2.com", "rv-b@wso2.com", "rv+plus@wso2.com"];

service /people/employees/basic\-info on jwksListener {
    isolated resource function get .() returns json|http:Response {
        string mode;
        lock {
            directoryFetches += 1;
        }
        lock {
            mode = directoryMode;
        }
        if mode == "down" {
            http:Response res = new;
            res.statusCode = 418;
            return res;
        }
        if mode == "garbled" {
            return {teamName: "Rivers", members: [{name: "Bob Jones bob@wso2.com"}]};
        }
        json[] rows = from string m in RIVERS
            select {workEmail: m.toUpperAscii(), firstName: "R", lastName: m.substring(0, 4), team: "Rivers", subTeam: (), businessUnit: "Water", house: "Oak"};
        rows.push({workEmail: "rv-noteam@wso2.com", firstName: "N", team: (), subTeam: (), businessUnit: "Land"});
        return rows;
    }
}

// ---- Standings ---------------------------------------------------------------------------------

function standing(string id, int points, int rank) returns recognition:Standing => {
    periodKey: "ALL",
    employeeId: id,
    displayName: "Person " + id,
    email: id + "@wso2.com",
    totalPoints: points,
    rank,
    previousRank: (),
    pointsToNextRank: 0,
    pointsToTopN: 0,
    lastActivityAt: [1760000000, 0]
};

final readonly & recognition:Standing[] STANDINGS = [
    standing("lb-1", 500, 1), standing("lb-2", 400, 2), standing("rv-a", 300, 3), standing("lb-3", 200, 4),
    standing("rv-b", 150, 5), standing("rv-c", 100, 6)
].cloneReadOnly();

isolated int fakeStandingVersion = 7;

function bumpStandingVersion() {
    lock {
        fakeStandingVersion += 1;
    }
}

@test:Mock {functionName: "standingVersion"}
isolated function mockStandingVersion(string period) returns int|error {
    check dbGate();
    lock {
        return fakeStandingVersion;
    }
}

@test:Mock {functionName: "topStandings"}
isolated function mockTopStandings(string period, int topN) returns recognition:Standing[]|error {
    check dbGate();
    return STANDINGS.slice(0, topN < STANDINGS.length() ? topN : STANDINGS.length()).clone();
}

@test:Mock {functionName: "standingOf"}
isolated function mockStandingOf(types:EmployeeId employeeId, string period) returns recognition:Standing|error? {
    check dbGate();
    foreach recognition:Standing s in STANDINGS {
        if s.employeeId == employeeId {
            return s.clone();
        }
    }
    return ();
}

@test:Mock {functionName: "standingEmailOf"}
isolated function mockStandingEmailOf(types:EmployeeId employeeId) returns string|error? {
    check dbGate();
    foreach recognition:Standing s in STANDINGS {
        if s.employeeId == employeeId {
            return s.email;
        }
    }
    return ();
}

@test:Mock {functionName: "teamPageOf"}
isolated function mockTeamPageOf(string period, string[]? emails, string? q, recognition:TeamSort sort, int page, int size)
        returns recognition:TeamPage|error {
    check dbGate();
    recognition:Standing[] rows = from recognition:Standing s in STANDINGS
        where (emails is () || emails.indexOf(s.email) !is ()) && (q is () || s.displayName.includes(q))
        select s;
    recognition:TeamEntry[] items = [];
    foreach int i in 0 ..< rows.length() {
        if i >= page * size && i < (page + 1) * size {
            items.push({standing: rows[i].clone(), teamRank: i + 1});
        }
    }
    return {items, total: rows.length()};
}

@test:Mock {functionName: "rosterPageOf"}
isolated function mockRosterPageOf(string period, recognition:RosterMember[] members, string? q, recognition:TeamSort sort,
        int page, int size) returns recognition:RosterPage|error {
    check dbGate();
    recognition:RosterEntry[] all = [];
    foreach recognition:RosterMember m in members {
        string email = m.email.toLowerAscii();
        recognition:Standing? s = ();
        foreach recognition:Standing candidate in STANDINGS {
            if candidate.email == email {
                s = candidate.clone();
            }
        }
        string name = m.name != "" ? m.name : (s is recognition:Standing ? s.displayName : email);
        all.push({employeeId: s is recognition:Standing ? s.employeeId : (), displayName: name, email,
            totalPoints: s is recognition:Standing ? s.totalPoints : 0, rank: s is recognition:Standing ? s.rank : (),
            previousRank: (), lastActivityAt: (), teamRank: 0});
    }
    recognition:RosterEntry[] ordered = from var e in all
        order by e.totalPoints descending, e.displayName ascending, e.email ascending
        select e;
    int active = ordered.filter(e => e.totalPoints > 0).length();
    // Dense rank over points, like the SQL's window.
    int rank = 0;
    int last = int:MAX_VALUE;
    foreach recognition:RosterEntry e in ordered {
        if e.totalPoints != last {
            rank += 1;
            last = e.totalPoints;
        }
        e.teamRank = rank;
    }
    recognition:RosterEntry[] matching = from var e in ordered
        where q is () || e.displayName.includes(q)
        select e;
    recognition:RosterEntry[] items = [];
    foreach int i in 0 ..< matching.length() {
        if i >= page * size && i < (page + 1) * size {
            items.push(matching[i]);
        }
    }
    return {items, total: matching.length(), activeCount: active};
}

@test:Mock {functionName: "pointsByEmailOf"}
isolated function mockPointsByEmailOf(string period) returns recognition:EmailPoints[]|error {
    check dbGate();
    return from recognition:Standing s in STANDINGS
        select {email: s.email, totalPoints: s.totalPoints};
}

@test:Mock {functionName: "monthlyPoints"}
isolated function mockMonthlyPoints(types:EmployeeId employeeId) returns recognition:MonthPoints[]|error {
    check dbGate();
    return [{month: "2026-10", points: 30, actions: 2}, {month: "2026-09", points: 10, actions: 1}];
}

@test:Mock {functionName: "ledgerHistory"}
isolated function mockLedgerHistory(types:EmployeeId employeeId, int page, int size) returns scoring:LedgerPage|error {
    check dbGate();
    types:LedgerEntry entry = {
        reference: "ADJ:" + employeeId + ":1",
        employeeId,
        campaignId: (),
        sourceType: types:ADJUSTMENT,
        action: (),
        points: 10,
        reason: "Welcome bonus",
        reversesReference: (),
        actorId: "po-0001",
        createdAt: [1760000000, 0],
        status: (),
        sourceId: (),
        ruleId: (),
        correlationId: (),
        statusChangedAt: (),
        paidAt: (),
        coinReference: ()
    };
    return {items: [entry], total: 1};
}

@test:Mock {functionName: "sharesOf"}
isolated function mockSharesOf(types:EmployeeId employeeId) returns sharing:ShareView[]|error {
    check dbGate();
    return [];
}

@test:Mock {functionName: "claimsOf"}
isolated function mockClaimsOf(types:EmployeeId employeeId) returns external_sharing:ExternalShare[]|error {
    check dbGate();
    return [];
}

@test:Mock {functionName: "claimsForReview"}
isolated function mockClaimsForReview(external_sharing:ExternalShareStatus? status, int page, int size)
        returns external_sharing:ExternalSharePage|error {
    check dbGate();
    return {items: [], total: 0};
}

isolated int dashboardBuilds = 0;

function dashboardBuildCount() returns int {
    lock {
        return dashboardBuilds;
    }
}

@test:Mock {functionName: "dashboardData"}
isolated function mockDashboardData(string month, int slaHours, time:Utc now) returns json|error {
    check dbGate();
    lock {
        dashboardBuilds += 1;
    }
    return {asOf: time:utcToString(now), month, reviewQueue: {pending: 0, oldestPendingAt: (), overSla: 0, slaHours}};
}

// ---- LinkedIn OAuth, cipher, OAuth state, tokens ----------------------------------------------------

# How the fake LinkedIn answers the code exchange.
type LinkedInMode "OK"|"REJECTED"|"DOWN"|"OFF"|"REVOKE_DOWN";

// Tokens the fake LinkedIn was asked to revoke.
isolated string[] revokedTokens = [];

function revokedSoFar() returns string[] {
    lock {
        return revokedTokens.clone();
    }
}

isolated LinkedInMode linkedInMode = "OK";

function setLinkedInMode(LinkedInMode mode) {
    lock {
        linkedInMode = mode;
    }
}

isolated function currentLinkedInMode() returns LinkedInMode {
    lock {
        return linkedInMode;
    }
}

isolated class FakeLinkedIn {
    *linkedin:ProviderAdapter;

    public isolated function authorizationUrl(string state) returns string|linkedin:ProviderError =>
        "https://www.linkedin.com/oauth/v2/authorization?response_type=code&state=" + state;

    public isolated function authorizationUrlWithNonce(string state, string? nonce) returns string|linkedin:ProviderError =>
        "https://www.linkedin.com/oauth/v2/authorization?response_type=code&state=" + state
            + (nonce is string ? "&nonce=" + nonce : "");

    public isolated function exchangeCode(string code) returns linkedin:TokenGrant|linkedin:ProviderError {
        LinkedInMode mode = currentLinkedInMode();
        if mode == "REJECTED" {
            return error linkedin:ProviderError("bad code", code = linkedin:REJECTED, httpStatus = 400,
                serviceErrorCode = (), retryable = false);
        }
        if mode == "DOWN" {
            return error linkedin:ProviderError("down", code = linkedin:UNAVAILABLE, httpStatus = 503,
                serviceErrorCode = (), retryable = true);
        }
        return {accessToken: "li-token-" + code, expiresInSeconds: 5184000, scopes: ["openid", "profile", "w_member_social"],
            idToken: nextIdToken()};
    }

    public isolated function userInfo(string accessToken) returns linkedin:MemberProfile|linkedin:ProviderError =>
        {sub: "li-" + accessToken, memberUrn: "urn:li:person:" + accessToken.substring(accessToken.length() - 6),
            name: (), email: ()};

    public isolated function revokeToken(string accessToken) returns linkedin:ProviderError? {
        if currentLinkedInMode() == "REVOKE_DOWN" {
            return error linkedin:ProviderError("down", code = linkedin:UNAVAILABLE, httpStatus = 503,
                serviceErrorCode = (), retryable = true);
        }
        lock {
            revokedTokens.push(accessToken);
        }
    }

    public isolated function publishShare(string accessToken, linkedin:ShareCommand command)
            returns types:PostUrn|linkedin:ProviderError =>
        error linkedin:ProviderError("not in api tests", code = linkedin:UNAVAILABLE, httpStatus = 503,
            serviceErrorCode = (), retryable = true);
}

final FakeLinkedIn fakeLinkedIn = new;

// ID token the fake's next code exchange returns (`()` = none, as LinkedIn without `openid`).
isolated string? idTokenOnExchange = ();

function setIdTokenOnExchange(string? token) {
    lock {
        idTokenOnExchange = token;
    }
}

isolated function nextIdToken() returns string? {
    lock {
        return idTokenOnExchange;
    }
}

@test:Mock {functionName: "linkedInProvider"}
isolated function mockLinkedInProvider() returns linkedin:ProviderAdapter? =>
    currentLinkedInMode() == "OFF" ? () : fakeLinkedIn;

final crypto:TokenCipher testCipher = check new ([check crypto:keyFromBase64("k1",
    "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");

@test:Mock {functionName: "cipher"}
isolated function mockCipher() returns crypto:TokenCipher? => testCipher;

@test:Mock {functionName: "redirectUri"}
isolated function mockRedirectUri() returns string => TEST_REDIRECT_URI;

isolated class FakeOAuthStates {
    *connection:OAuthStateRepository;
    private map<connection:OAuthState> rows = {};

    public isolated function issue(connection:OAuthState state) returns error? {
        lock {
            self.rows[state.state] = state.clone();
        }
    }

    public isolated function consume(string state, types:EmployeeId employeeId, time:Utc now)
            returns connection:OAuthState|error? {
        lock {
            connection:OAuthState? row = self.rows[state];
            if row is () || row.employeeId != employeeId || time:utcDiffSeconds(row.expiresAt, now) <= 0d {
                return ();
            }
            _ = self.rows.remove(state);
            return row.clone();
        }
    }
}

isolated class FakeTokens {
    *connection:TokenRepository;
    private connection:StoredToken[] rows = [];

    public isolated function insert(connection:StoredToken token) returns error? {
        lock {
            self.rows.push(token.clone());
        }
    }

    private map<connection:StoredToken> seeded = {};

    # Makes `find` return this row (a connection whose token can be opened and revoked).
    isolated function seed(connection:StoredToken token) {
        lock {
            self.seeded[token.tokenId] = token.clone();
        }
    }

    public isolated function find(connection:TokenRef ref) returns connection:StoredToken|error? {
        lock {
            return self.seeded[ref.tokenId].clone();
        }
    }

    isolated function count() returns int {
        lock {
            return self.rows.length();
        }
    }
}

final FakeOAuthStates fakeOAuthStates = new;
final FakeTokens fakeTokens = new;

@test:Mock {functionName: "oauthStateRepository"}
isolated function mockOAuthStateRepository() returns connection:OAuthStateRepository|error => fakeOAuthStates;

@test:Mock {functionName: "tokenRepository"}
isolated function mockTokenRepository() returns connection:TokenRepository|error => fakeTokens;

// ---- Announcements --------------------------------------------------------------------------------

isolated class FakeAnnouncements {
    *announcements:AnnouncementRepository;
    private map<announcements:Announcement> rows = {};

    isolated function put(announcements:Announcement a) {
        lock {
            self.rows[a.campaignId] = a.clone();
        }
    }

    public isolated function findByCampaign(string campaignId) returns announcements:Announcement|error? {
        lock {
            return self.rows[campaignId].clone();
        }
    }

    public isolated function list(announcements:AnnouncementStatus? status, int 'limit)
            returns announcements:Announcement[]|error {
        announcements:Announcement[] all;
        lock {
            all = self.rows.toArray().clone();
        }
        return from announcements:Announcement a in all
            where status is () || announcements:announcementStatus(a) == status
            select a;
    }

    public isolated function requeue(string campaignId) returns error? {
        lock {
            announcements:Announcement? a = self.rows[campaignId];
            if a is announcements:Announcement {
                announcements:Announcement queued = a.clone();
                queued.failedAt = ();
                queued.lastError = ();
                self.rows[campaignId] = queued;
            }
        }
    }
}

final FakeAnnouncements fakeAnnouncements = new;

@test:Mock {functionName: "announcementRepository"}
isolated function mockAnnouncementRepository(store:Actor actor) returns announcements:AnnouncementRepository|error =>
    fakeAnnouncements;

// ---- Dashboards (ADR-036) -------------------------------------------------------------------------

const time:Utc DASH_NOW = [1761000000, 0];

isolated function dashPost(string id, string title, string cat, boolean priority, string status, int openedDaysAgo, int reposts,
        int withCommentary = 0)
        returns reporting:CampaignRow => {
    campaignId: id,
    title,
    categoryCode: cat,
    categoryLabel: cat == "PRODUCT" ? "Product" : "Event",
    isPriority: priority,
    status,
    opensAt: time:utcAddSeconds(DASH_NOW, <decimal>(-86400 * openedDaysAgo)),
    closesAt: time:utcAddSeconds(DASH_NOW, <decimal>(86400 * (30 - openedDaysAgo))),
    reposts,
    repostsWithCommentary: withCommentary
};

isolated Snapshot? fakeSnapshot = ();
isolated int snapshotLoads = 0;

isolated function fixedSnapshot() returns Snapshot => {
    asOf: DASH_NOW,
    live: {live: 2, livePriority: 1, closingWithin7Days: 1},
    repostsThisMonth: 90,
    repostsThisMonthWithCommentary: 15,
    repostsPrevMonth: 50,
    monthly: from int i in 0 ..< 6
        select {monthStart: string `2026-${i + 4 < 10 ? "0" : ""}${i + 4}-01`, reposts: i * 5},
    connections: {active: 1, expiring: 0, expired: 1, revoked: 0},
    participation: {connected: 2, expired: 1, reposted: 30, active30Days: 25},
    points: {month: 500, year: 4000},
    peopleWithPoints: 28,
    campaigns: [
        dashPost("p-launch", "Launch", "PRODUCT", true, "OPEN", 3, 40, 12),
        dashPost("p-event", "Event", "EVENT", false, "OPEN", 10, 10),
        dashPost("p-old", "Old news", "PRODUCT", false, "CLOSED", 20, 5),
        dashPost("p-ancient", "Ancient", "EVENT", false, "CLOSED", 80, 99)
    ],
    delivery: {
        "p-launch": {status: "SENT", attempts: (), sentAt: DASH_NOW},
        "p-event": {status: "QUEUED", attempts: 3, sentAt: ()}
    },
    shares: {queued: 1, published: 57, failed: 3, failedByReason: {NEEDS_RECONNECT: 2, PROVIDER_REJECTED: 1, RETRIES_EXHAUSTED: 0}},
    cards: {total: 3, sent: 2, queued: 1, failed: 0, retrying: 1}
};

# Replaces the snapshot the fake database answers with, and drops the cached one.
#
# + s - Snapshot, or `()` for the fixed one
function setSnapshot(Snapshot? s = ()) {
    lock {
        fakeSnapshot = s is () ? fixedSnapshot() : s.clone();
    }
    lock {
        snapshotCache = ();
    }
}

function takeSnapshotLoads() returns int {
    lock {
        int n = snapshotLoads;
        snapshotLoads = 0;
        return n;
    }
}

@test:Mock {functionName: "loadSnapshot"}
isolated function mockLoadSnapshot(time:Utc now) returns Snapshot|error {
    check dbGate();
    lock {
        snapshotLoads += 1;
    }
    lock {
        Snapshot? s = fakeSnapshot;
        return s is () ? fixedSnapshot().clone() : s.clone();
    }
}

@test:Mock {functionName: "categoryCounts"}
isolated function mockCategoryCounts(time:Utc since) returns reporting:CategoryCount[]|error {
    check dbGate();
    return [{code: "PRODUCT", label: "Product", reposts: 45, repostsWithCommentary: 12},
        {code: "EVENT", label: "Event", reposts: 10, repostsWithCommentary: 0}];
}

@test:Mock {functionName: "campaignByDay"}
isolated function mockPostByDay(string campaignId) returns int[]|error {
    check dbGate();
    return campaignId == "p-launch" ? [30, 5, 3, 1, 1, 0, 0] : [1, 0, 0, 0, 0, 0, 0];
}

@test:Mock {functionName: "campaignPeople"}
isolated function mockCampaignPeople(string campaignId) returns [reporting:CampaignCard, reporting:Reposter[]]|error {
    check dbGate();
    return [{summary: "Launch day", imageUrl: "https://example.com/launch.png", resourceUrl: "https://www.linkedin.com/feed/update/urn:li:share:1", resourceUrn: "urn:li:share:1"},
        [{employeeId: "e1", displayName: "Ada Lovelace", email: "ada@example.com", withCommentary: false},
        {employeeId: "e2", displayName: "Grace Hopper", email: (), withCommentary: true},
        {employeeId: "e3", displayName: "Alan Turing", email: "alan@example.com", withCommentary: false}]];
}

@test:Mock {functionName: "exportRows"}
isolated function mockExportRows(time:Utc 'from, time:Utc to) returns reporting:ExportRow[]|error {
    check dbGate();
    return [
        {recordType: "ENGAGEMENT", occurredAt: "2025-10-20T10:00:00Z", campaignId: "p-launch", campaignTitle: "Launch, big", category: "Product",
            isPriority: true, employeeId: "e1", employeeName: "=Ada \"AL\" Lovelace", employeeEmail: "ada@example.com",
            action: "REPOST", status: "ACTIVE", points: (), detail: ()},
        {recordType: "POINTS", occurredAt: "2025-10-20T10:00:01Z", campaignId: (), campaignTitle: (), category: (), isPriority: (),
            employeeId: "e1", employeeName: (), employeeEmail: (), action: "REPOST", status: "HELD", points: 5, detail: "ENGAGEMENT"}
    ];
}

@test:Mock {functionName: "personPosts"}
isolated function mockPersonPosts(string employeeId) returns [reporting:PersonIdentity, reporting:PersonPost[], int]?|error {
    check dbGate();
    if employeeId == "nobody" {
        return ();
    }
    time:Utc opened = check time:utcFromString("2025-10-19T00:00:00Z");
    time:Utc closed = check time:utcFromString("2025-11-18T00:00:00Z");
    return [{employeeId, displayName: "Ada Lovelace", email: "ada@example.com"},
        [{campaignId: "p-launch", title: "Launch", categoryCode: "PRODUCT", categoryLabel: "Product", isPriority: true, opensAt: opened,
            closesAt: closed, reposts: 1, repostsWithCommentary: 1, points: 15},
        {campaignId: "p-event", title: "Event", categoryCode: "EVENT", categoryLabel: "Event", isPriority: false, opensAt: opened,
            closesAt: closed, reposts: 0, repostsWithCommentary: 1, points: 10}], 20];
}
