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


// Egress from amplify-api (declared Choreo connections only): the amplify-jobs trigger, the people
// directory for team rosters (D13) and LinkedIn OAuth (S2). Each HTTP client has a timeout and a circuit breaker; the
// jobs trigger and the roster are non-fatal, so their failures degrade the response instead of failing it.

import amplify_api.scheduler;
import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.resilience;
import amplify_domain.recognition;

import ballerina/http;
import ballerina/log;
import ballerina/time;

// ---- amplify-jobs ---------------------------------------------------------------------------------

# amplify-jobs base URL (Project visibility). Empty = not configured: triggers are skipped (the scheduled Run catches up).
configurable string jobsUrl = "";
# Trigger timeout, seconds.
configurable decimal jobsTimeoutSeconds = 3;
# Secret amplify-jobs accepts on every route (a Choreo secret; locally `AMPLIFY_INTERNAL_API_KEY`). Sent on the
# triggers below only. Required whenever `jobsUrl` is set. Never put on the scheduler's jobs (ADR-039).
configurable string internalApiKey = "";

# Secret amplify-jobs accepts only on `POST /runs` and `POST /maintenance/partitions` (a Choreo secret; locally
# `AMPLIFY_SCHEDULER_API_KEY`). Set as a header on the jobs registered with the scheduler. Required whenever
# `schedulerUrl` is set, and must differ from `internalApiKey`.
configurable string schedulerApiKey = "";

# Shortest key accepted (a 24-byte random value as hex is 48 characters).
const int MIN_INTERNAL_KEY_LENGTH = 32;

# Stops start-up when a key a configured target needs is missing or too short, or when the two keys are equal, so
# a deployment can't quietly send unauthenticated calls that amplify-jobs will refuse, or hand the scheduler the
# full-access key.
#
# + jobs - `jobsUrl`
# + scheduler - `schedulerUrl`
# + internal - `internalApiKey`
# + schedulerKey - `schedulerApiKey`
# + return - An error naming the problem, or `()`
isolated function checkApiKeys(string jobs, string scheduler, string internal, string schedulerKey) returns error? {
    if jobs.trim() != "" && internal.trim().length() < MIN_INTERNAL_KEY_LENGTH {
        return error(string `internalApiKey must be a secret of at least ${MIN_INTERNAL_KEY_LENGTH} characters `
                + "when jobsUrl is set");
    }
    if scheduler.trim() != "" && schedulerKey.trim().length() < MIN_INTERNAL_KEY_LENGTH {
        return error(string `schedulerApiKey must be a secret of at least ${MIN_INTERNAL_KEY_LENGTH} characters `
                + "when schedulerUrl is set");
    }
    if internal.trim() != "" && internal.trim() == schedulerKey.trim() {
        return error("schedulerApiKey must differ from internalApiKey");
    }
}

# The header each scheduler job carries into amplify-jobs: the scheduler key, never the internal key.
#
# + return - One header, or none when no scheduler key is configured (only possible when no scheduler is configured)
isolated function schedulerKeyHeaders() returns scheduler:Header[] =>
    schedulerApiKey.trim() == "" ? [] : [{name: INTERNAL_KEY_HEADER, value: schedulerApiKey.trim()}];

final http:Client? jobsClient = check newBreakerClient(jobsUrl, jobsTimeoutSeconds);

// ---- People directory: team rosters (D13, leaderboards.md) -----------------------------------------

# people-app's employee directory, the full `GET .../employees/basic-info` URL (the same source One WSO2's
# Org Chart reads). One call returns every current employee with `workEmail`, `team` and `subTeam`.
# Empty = not configured (`teamStatus: UNAVAILABLE`).
configurable string peopleDirectoryUrl = "";
# Directory timeout, seconds. One response for the whole company, so longer than the other calls.
configurable decimal peopleDirectoryTimeoutSeconds = 10;
# OAuth2 client credentials for the directory's API (the Choreo connection's token URL and keys).
# Empty token URL = no auth header (local stubs only).
configurable string peopleDirectoryTokenUrl = "";
# Directory client id (Choreo connection consumer key).
configurable string peopleDirectoryClientId = "";
# Directory client secret (Choreo secret).
configurable string peopleDirectoryClientSecret = "";
# How long the directory results (teams, names, houses) are reused, seconds (default 24 hours). Memory
# only, never written to the database. Only a successful read is kept: a failed refresh keeps serving the
# previous result and asks the directory again on the next call, so an outage is never cached.
configurable decimal rosterCacheSeconds = 86400;
# How long the employee count is reused, seconds (default 24 hours, the same directory read). Memory only,
# never written to the database. When it runs out the directory is fetched again, whatever age the team
# index has.
configurable decimal headcountCacheSeconds = 86400;

final http:Client? peopleDirectoryClient = check newBreakerClient(peopleDirectoryUrl, peopleDirectoryTimeoutSeconds,
        peopleDirectoryAuth());

// ---- LinkedIn (S2) ------------------------------------------------------------------------------------

# LinkedIn OAuth client id. Empty = connect is unavailable (503).
configurable string linkedinClientId = "";
# LinkedIn OAuth client secret (Choreo secret).
configurable string linkedinClientSecret = "";
# Redirect URI registered on the LinkedIn app (the One WSO2 callback page).
configurable string linkedinRedirectUri = "";
# REST API base (mock_linkedin locally).
configurable string linkedinApiBaseUrl = "https://api.linkedin.com";
# OAuth base (mock_linkedin locally).
configurable string linkedinAuthBaseUrl = "https://www.linkedin.com";
# Browser-facing OAuth base for the authorization URL. Empty = `linkedinAuthBaseUrl` (local Compose only).
configurable string linkedinAuthorizeBaseUrl = "";
# Token keys, `keyId:base64Key` comma separated (Choreo secret).
configurable string tokenKeys = "";
# Key id used for new tokens.
configurable string tokenCurrentKeyId = "";

# Validate the OIDC ID token from the code exchange (common H1 / api H1): RS256 against LinkedIn's JWKS,
# `iss`, `aud` = client id, `exp`/`iat`, and its `sub` must match userinfo. Off by default until a real
# LinkedIn app has been seen to return the ID token for this flow. No PKCE: it is native-client-only at
# LinkedIn. The nonce is `linkedinNonceMode`.
configurable boolean linkedinIdTokenValidation = false;
# OIDC `nonce` on connect, only with `linkedinIdTokenValidation` on (the nonce lives in the ID token).
# `OFF` (default): none is sent. `SEND`: it is sent on the authorize request and, when the ID token carries a
# `nonce`, it must match; a token with none is accepted and logged (`nonce not echoed`), so a staging run shows
# whether LinkedIn echoes it. `REQUIRE`: the ID token must carry the same nonce, or the connect is refused.
# LinkedIn's documentation lists neither a `nonce` request parameter nor a `nonce` claim (its discovery
# document's `claims_supported` has none), so nothing may go past `SEND` until a real app is seen to echo it.
configurable string linkedinNonceMode = "OFF";
# LinkedIn's OIDC signing keys (mock_linkedin's JWKS locally).
configurable string linkedinJwksUrl = linkedin:LINKEDIN_JWKS_URL;
# Expected ID-token issuer.
configurable string linkedinOidcIssuer = linkedin:LINKEDIN_OIDC_ISSUER;

final linkedin:ProviderAdapter? linkedInAdapter = check newLinkedInAdapter();
final crypto:TokenCipher? tokenCipher = check newTokenCipher();
final linkedin:IdTokenValidator? idTokenValidator = check newIdTokenValidator();

isolated function newBreakerClient(string url, decimal timeout, http:ClientAuthConfig? auth = ())
        returns http:Client?|error {
    if url == "" {
        return ();
    }
    http:ClientConfiguration config = {
        timeout,
        circuitBreaker: {
            rollingWindow: {timeWindow: 60, bucketSize: 10, requestVolumeThreshold: 1},
            failureThreshold: 0.5,
            resetTime: 30,
            statusCodes: [500, 502, 503, 504]
        }
    };
    if auth is http:ClientAuthConfig {
        config.auth = auth;
    }
    return check new (url, config);
}

isolated function peopleDirectoryAuth() returns http:OAuth2ClientCredentialsGrantConfig? {
    if peopleDirectoryTokenUrl == "" {
        return ();
    }
    return {tokenUrl: peopleDirectoryTokenUrl, clientId: peopleDirectoryClientId,
        clientSecret: peopleDirectoryClientSecret};
}

isolated function newLinkedInAdapter() returns linkedin:ProviderAdapter?|error {
    if linkedinClientId == "" {
        return ();
    }
    check checkRedirectUri(linkedinRedirectUri, environment);
    return check new linkedin:LinkedInAdapter({
        apiBaseUrl: linkedinApiBaseUrl,
        authBaseUrl: linkedinAuthBaseUrl,
        authorizeBaseUrl: linkedinAuthorizeBaseUrl,
        clientId: linkedinClientId,
        clientSecret: linkedinClientSecret,
        redirectUri: linkedinRedirectUri
    });
}

isolated function newIdTokenValidator() returns linkedin:IdTokenValidator?|error {
    if !linkedinIdTokenValidation || linkedinClientId == "" {
        return ();
    }
    return check new linkedin:IdTokenValidator({clientId: linkedinClientId, issuer: linkedinOidcIssuer,
        jwksUrl: linkedinJwksUrl});
}

isolated function newTokenCipher() returns crypto:TokenCipher?|error {
    if tokenKeys.trim() == "" {
        return ();
    }
    crypto:TokenKey[] keys = [];
    foreach string item in re `,`.split(tokenKeys) {
        string[] parts = re `:`.split(item.trim());
        if parts.length() != 2 {
            return error("tokenKeys must be keyId:base64Key pairs");
        }
        keys.push(check crypto:keyFromBase64(parts[0], parts[1]));
    }
    return check new crypto:TokenCipher(keys, tokenCurrentKeyId);
}

# Refuses a LinkedIn redirect URI that the token exchange shouldn't carry: it must be an absolute HTTPS URL
# (plain HTTP only on `environment = local`, for the local One WSO2 page) with no query, fragment or
# credentials. The same value goes on the authorize request and the token exchange, and
# `completeConnect` checks the caller's `redirectUri` against it.
#
# + uri - `linkedinRedirectUri`
# + env - `environment`
# + return - An error that stops startup, or `()`
isolated function checkRedirectUri(string uri, string env) returns error? {
    boolean https = uri.startsWith("https://");
    boolean localHttp = env == "local" && uri.startsWith("http://");
    if !https && !localHttp {
        return error("linkedinRedirectUri must be an absolute https:// URL (http:// only when environment is local)");
    }
    string rest = uri.substring(uri.indexOf("://") is int ? <int>uri.indexOf("://") + 3 : 0);
    if uri.length() > 2048 || rest.length() == 0 || rest.startsWith("/") || rest.includes("?") || rest.includes("#")
            || rest.includes("@") || re `[\s\\]`.find(uri) !is () {
        return error("linkedinRedirectUri must have a host and no query, fragment, credentials or spaces");
    }
}

# Test seam: the configured LinkedIn redirect URI (what the authorize request and the token exchange carry).
#
# + return - The URI
isolated function redirectUri() returns string => linkedinRedirectUri;

# Test seam: the LinkedIn adapter.
#
# + return - The adapter, or `()` when not configured
isolated function linkedInProvider() returns linkedin:ProviderAdapter? => linkedInAdapter;

# Test seam: the ID-token validator.
#
# + return - The validator, or `()` when `linkedinIdTokenValidation` is off
isolated function idTokens() returns linkedin:IdTokenValidator? => idTokenValidator;

# How the nonce is used for this connect (test seam for the configured mode).
#
# + validator - The ID-token validator, `()` when validation is off
# + return - `OFF` without a validator or when unset, else the configured `SEND` / `REQUIRE`
isolated function nonceModeFor(linkedin:IdTokenValidator? validator) returns NonceMode {
    if validator is () {
        return "OFF";
    }
    return linkedinNonceMode == "SEND" ? "SEND" : linkedinNonceMode == "REQUIRE" ? "REQUIRE" : "OFF";
}

# `linkedinNonceMode`.
type NonceMode "OFF"|"SEND"|"REQUIRE";

# Test seam: the token cipher.
#
# + return - The cipher, or `()` when not configured
isolated function cipher() returns crypto:TokenCipher? => tokenCipher;

# Breaker state as `/ready` reports it (openapi `BreakerState`); `NOT_CONFIGURED` is -1 on the gauge (ADR-028).
type BreakerReport "CLOSED"|"HALF_OPEN"|"OPEN"|"NOT_CONFIGURED";

# Breaker state name for `/ready`.
#
# + c - Client, or `()` when not configured
# + return - `CLOSED`, `HALF_OPEN`, `OPEN`, or `NOT_CONFIGURED` when the dependency has no URL
isolated function breakerOf(http:Client? c) returns BreakerReport {
    if c is () {
        return "NOT_CONFIGURED";
    }
    http:CircuitState state = c.getCircuitBreakerCurrentState();
    return state == http:CB_OPEN_STATE ? "OPEN" : state == http:CB_HALF_OPEN_STATE ? "HALF_OPEN" : "CLOSED";
}

# Every breaker of amplify-api, for `/ready` and the metrics gauge.
#
# + jwks - JWKS breaker state
# + return - State by dependency (`NOT_CONFIGURED` when a dependency isn't set up)
isolated function breakerStates(BreakerReport jwks) returns map<BreakerReport> {
    linkedin:ProviderAdapter? li = linkedInAdapter;
    map<resilience:BreakerState> liStates = li is linkedin:LinkedInAdapter ? li.breakers() : {};
    linkedin:IdTokenValidator? idv = idTokens();
    return {
        database: dbBreakerState(),
        jwks,
        jobs: breakerOf(jobsClient),
        roster: breakerOf(peopleDirectoryClient),
        linkedinOAuth: liStates["auth"] ?: "NOT_CONFIGURED",
        linkedinApi: liStates["api"] ?: "NOT_CONFIGURED",
        // Reported, not gating (like linkedinOAuth): only the connect flow needs it.
        linkedinIdTokenJwks: idv is () ? "NOT_CONFIGURED" : idv.breaker()
    };
}

// ---- Calls ------------------------------------------------------------------------------------------

# What the jobs trigger did (openapi `CampaignRegistration.run`).
type RunTrigger "NOT_REQUESTED"|"STARTED"|"DEFERRED";

# Asks amplify-jobs to start a Run, fire-and-forget (plan M5 `shareNow`). Never fails the caller.
#
# + path - `/runs` or `/maintenance/rebuild-recognition`
# + correlationId - Propagated as `X-Correlation-ID`
# + return - `STARTED` when the trigger was sent, `DEFERRED` when jobs isn't configured or the breaker is open
isolated function triggerJobs(string path, string? correlationId) returns RunTrigger {
    http:Client? c = jobsClient;
    if c is () || c.getCircuitBreakerCurrentState() == http:CB_OPEN_STATE {
        log:printWarn("amplify-jobs trigger deferred to the scheduled Run", path = path, correlationId = correlationId);
        return "DEFERRED";
    }
    _ = start sendTrigger(c, path, correlationId);
    return "STARTED";
}

isolated function sendTrigger(http:Client c, string path, string? correlationId) {
    map<string> headers = correlationId is string ? {[CORRELATION_HEADER]: correlationId} : {};
    if internalApiKey.trim() != "" {
        headers[INTERNAL_KEY_HEADER] = internalApiKey.trim();
    }
    http:Response|error res = c->post(path, {}, headers);
    if res is error {
        log:printWarn("amplify-jobs trigger failed; the scheduled Run will catch up", 'error = res, path = path,
                correlationId = correlationId);
    } else if res.statusCode >= 400 {
        log:printWarn("amplify-jobs trigger refused; the scheduled Run will catch up", status = res.statusCode, path = path,
                correlationId = correlationId);
    }
}

# Whether the people directory is configured (test seam).
#
# + return - True when `peopleDirectoryUrl` is set
isolated function rosterConfigured() returns boolean => peopleDirectoryClient !is ();

# A team roster.
type Roster record {|
    # Team name (the sub-team, or the team when there is no sub-team)
    string teamName;
    # Member emails, lowercase
    string[] emails;
    # House of each member that has one, by lowercase email
    map<string> houses = {};
    # Display name of each member that has one, by lowercase email (directory first and last name)
    map<string> names = {};
|};

# The fields of a directory row Amplify reads. Open: the row carries more (names, photo, manager), which
# is ignored and never kept.
type DirectoryRecord record {
    # Work email. Optional: one row without it (a contractor, a placeholder) is skipped, not a reason to
    # reject the whole directory.
    string? workEmail = ();
    # First name
    string? firstName = ();
    # Last name
    string? lastName = ();
    # Team
    string? team = ();
    # Sub-team
    string? subTeam = ();
    # Business unit (BU), the level above team
    string? businessUnit = ();
    # House (a company-wide grouping that cuts across BUs and teams)
    string? house = ();
};

# Everyone's team, built from one directory response.
type DirectoryIndex record {|
    # Lowercase email to team key
    map<string> teamOf;
    # Team key to display name
    map<string> teamNames;
    # Team key to member emails, lowercase
    map<string[]> members;
    # Lowercase email to business unit name (people without one are left out)
    map<string> buOf;
    # Business unit name to member emails, lowercase
    map<string[]> buMembers;
    # Lowercase email to house name (people without one are left out)
    map<string> houseOf;
    # House name to member emails, lowercase
    map<string[]> houseMembers;
    # Team key to its business unit, as the directory states it (the key carries it, so a team is never
    # guessed into a BU)
    map<string> teamBu;
    # Everyone the directory returned with a work email, whether or not they have a team
    int total;
    # Lowercase email to display name (first and last name; people without a name are left out)
    map<string> nameOf;
    # Everyone's lowercase email, in directory order (the company roster)
    string[] everyone;
|};

# The cached index and when it was built (monotonic seconds).
isolated [DirectoryIndex & readonly, decimal]? directoryCache = ();

# Groups the directory by team: the sub-team, or the team when a person has no sub-team. The key carries
# the business unit and the team, so two teams with a same-named sub-team stay apart, and a team's BU is
# always the one the directory gives its members, never worked out. People with neither team nor sub-team
# are left out of teams (they still count toward the headcount and their BU).
#
# + records - Directory rows
# + return - The index
isolated function indexDirectory(DirectoryRecord[] records) returns DirectoryIndex & readonly {
    map<string> teamOf = {};
    map<string> teamNames = {};
    map<string[]> members = {};
    map<string> buOf = {};
    map<string[]> buMembers = {};
    map<string> houseOf = {};
    map<string[]> houseMembers = {};
    map<string> teamBu = {};
    map<string> nameOf = {};
    string[] everyone = [];
    map<boolean> seen = {};
    foreach DirectoryRecord r in records {
        string email = (r.workEmail ?: "").trim().toLowerAscii();
        if email == "" || seen.hasKey(email) {
            continue;
        }
        seen[email] = true;
        everyone.push(email);
        string fullName = string `${(r.firstName ?: "").trim()} ${(r.lastName ?: "").trim()}`.trim();
        if fullName != "" {
            nameOf[email] = fullName;
        }
        string team = (r.team ?: "").trim();
        string subTeam = (r.subTeam ?: "").trim();
        string bu = (r.businessUnit ?: "").trim();
        string house = (r.house ?: "").trim();
        if house != "" {
            houseOf[email] = house;
            string[] houseList = houseMembers[house] ?: [];
            houseList.push(email);
            houseMembers[house] = houseList;
        }
        if bu != "" {
            buOf[email] = bu;
            string[] buList = buMembers[bu] ?: [];
            buList.push(email);
            buMembers[bu] = buList;
        }
        if team == "" && subTeam == "" {
            continue;
        }
        string key = string `${bu}/${team}/${subTeam}`;
        teamOf[email] = key;
        teamNames[key] = subTeam != "" ? subTeam : team;
        teamBu[key] = bu;
        string[] list = members[key] ?: [];
        list.push(email);
        members[key] = list;
    }
    return {teamOf, teamNames, members, buOf, buMembers, houseOf, houseMembers, teamBu, total: seen.length(), nameOf, everyone}.cloneReadOnly();
}

# The viewer's roster from the index.
#
# + index - Directory index
# + email - Viewer email
# + return - The roster, or `()` when the viewer isn't in the directory or has no team
isolated function rosterFrom(DirectoryIndex index, string email) returns Roster? {
    string? key = index.teamOf[email.trim().toLowerAscii()];
    if key is () {
        return ();
    }
    string[] emails = [...(index.members[key] ?: [])];
    map<string> houses = {};
    map<string> names = {};
    foreach string member in emails {
        string? house = index.houseOf[member];
        if house is string {
            houses[member] = house;
        }
        string? name = index.nameOf[member];
        if name is string {
            names[member] = name;
        }
    }
    return {teamName: index.teamNames[key] ?: key, emails, houses, names};
}

# A roster as the members the database joins to the standings.
#
# + roster - Roster
# + return - One member per email, with the directory's name when it has one
isolated function membersOf(Roster roster) returns recognition:RosterMember[] =>
    from string email in roster.emails
    select {email, name: roster.names[email] ?: ""};

# Everyone in the directory as roster members (the company-wide view).
#
# + index - Directory index
# + return - One member per person with a work email
isolated function everyoneIn(DirectoryIndex index) returns recognition:RosterMember[] =>
    from string email in index.everyone
    select {email, name: index.nameOf[email] ?: ""};

# The viewer's team roster. The whole directory is fetched once and reused for `rosterCacheSeconds`.
#
# + email - Viewer email
# + correlationId - Correlation id
# + return - The roster, `()` when the viewer has no team, or an error when the directory is unavailable
isolated function rosterOf(string email, string? correlationId) returns Roster|error? {
    DirectoryIndex index = check directoryIndex(correlationId);
    return rosterFrom(index, email);
}

# The team index: cached while fresh; refreshed after `rosterCacheSeconds`. A failed refresh keeps
# serving the old index (teams change rarely), so the directory being down only shows when nothing was
# ever loaded.
#
# + correlationId - Correlation id
# + return - The index, or an error when it was never loaded and the directory is unavailable
isolated function directoryIndex(string? correlationId) returns (DirectoryIndex & readonly)|error {
    decimal now = time:monotonicNow();
    (DirectoryIndex & readonly)? stale = ();
    lock {
        [DirectoryIndex & readonly, decimal]? hit = directoryCache;
        if hit is [DirectoryIndex & readonly, decimal] {
            if now - hit[1] < rosterCacheSeconds {
                return hit[0];
            }
            stale = hit[0];
        }
    }
    (DirectoryIndex & readonly)|error fresh = fetchDirectory(correlationId);
    if fresh is error {
        if stale is DirectoryIndex & readonly {
            log:printWarn("People directory refresh failed; using the cached teams", reason = fresh.message(),
                    correlationId = correlationId);
            return stale;
        }
        return fresh;
    }
    lock {
        directoryCache = [fresh, now];
    }
    return fresh;
}

isolated function fetchDirectory(string? correlationId) returns (DirectoryIndex & readonly)|error {
    http:Client? c = peopleDirectoryClient;
    if c is () {
        return error("People directory is not configured");
    }
    map<string> headers = correlationId is string ? {[CORRELATION_HEADER]: correlationId} : {};
    http:Response res = check c->get("", headers);
    if res.statusCode != 200 {
        return error(string `People directory answered ${res.statusCode}`);
    }
    // The body names people: a parse error's message can echo it, so it never reaches the log.
    json|error payload = res.getJsonPayload();
    DirectoryRecord[]|error records = payload is json ? payload.cloneWithType() : payload;
    if records is error {
        return error("People directory answered a malformed body");
    }
    return indexDirectory(records);
}

// ---- Employee count (headcount) ------------------------------------------------------------------------

# Employees in one business unit.
type BusinessUnitCount record {|
    # Business unit name
    string name;
    # Employees
    int headcount;
|};

# Employees in one house.
type HouseCount record {|
    # House name
    string name;
    # Employees
    int headcount;
|};

# Employees in one team.
type TeamCount record {|
    # Opaque team key (`team/subTeam`), what the board endpoints take as `team`
    string key;
    # Team name (the sub-team, or the team when there is no sub-team)
    string name;
    # Business unit most of the team sits in, `()` when the directory names none
    string? businessUnit;
    # Employees
    int headcount;
|};

# The employee count and where it was counted from.
type HeadcountSnapshot record {|
    # Everyone the directory returned with a work email
    int total;
    # By business unit, largest first
    BusinessUnitCount[] businessUnits;
    # By house, largest first
    HouseCount[] houses;
    # By team, largest first
    TeamCount[] teams;
    # When the directory was read (UTC)
    string asOf;
|};

# The employee count and when it was taken (monotonic seconds).
isolated [HeadcountSnapshot & readonly, decimal]? headcountCache = ();

# Counts a directory index.
#
# + index - Directory index
# + asOf - When the directory was read
# + return - The snapshot
isolated function headcountOf(DirectoryIndex index, time:Utc asOf) returns HeadcountSnapshot & readonly {
    BusinessUnitCount[] businessUnits = from var [name, emails] in index.buMembers.entries()
        let int n = emails.length()
        order by n descending, name ascending
        select {name, headcount: n};
    HouseCount[] houses = from var [name, emails] in index.houseMembers.entries()
        let int n = emails.length()
        order by n descending, name ascending
        select {name, headcount: n};
    TeamCount[] teams = from var [key, emails] in index.members.entries()
        let int n = emails.length()
        let string name = index.teamNames[key] ?: key
        let string bu = index.teamBu[key] ?: ""
        order by n descending, name ascending, key ascending
        select {key, name, businessUnit: bu == "" ? () : bu, headcount: n};
    return {total: index.total, businessUnits, houses, teams, asOf: time:utcToString(asOf)}.cloneReadOnly();
}

# The employee count: reused for `headcountCacheSeconds`, then counted again from a fresh directory call
# (which also refreshes the team index). A failed refresh keeps serving the last count.
#
# + correlationId - Correlation id
# + return - The count, or an error when it was never counted and the directory is unavailable
isolated function headcountSnapshot(string? correlationId) returns (HeadcountSnapshot & readonly)|error {
    decimal now = time:monotonicNow();
    (HeadcountSnapshot & readonly)? stale = ();
    lock {
        [HeadcountSnapshot & readonly, decimal]? hit = headcountCache;
        if hit is [HeadcountSnapshot & readonly, decimal] {
            if now - hit[1] < headcountCacheSeconds {
                return hit[0];
            }
            stale = hit[0];
        }
    }
    (DirectoryIndex & readonly)|error fresh = fetchDirectory(correlationId);
    if fresh is error {
        if stale is HeadcountSnapshot & readonly {
            log:printWarn("People directory refresh failed; using the cached employee count",
                    reason = fresh.message(), correlationId = correlationId);
            return stale;
        }
        return fresh;
    }
    HeadcountSnapshot & readonly snapshot = headcountOf(fresh, time:utcNow());
    lock {
        directoryCache = [fresh, now];
    }
    lock {
        headcountCache = [snapshot, now];
    }
    return snapshot;
}
