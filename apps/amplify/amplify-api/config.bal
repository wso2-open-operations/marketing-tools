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
import amplify_api.auth;

import ballerina/io;
import ballerina/log;
import ballerinax/postgresql;

// ---- Identity (ADR-022). Setup values: docs/runbooks/identity-setup.md ----------------------------

# Deployment environment: `local`, `dev`, `staging` or `prod`. Defaults to the strictest.
#
# Only `local` changes what the code does. Every other value, including one that is not on this list, is treated
# as a deployed environment, so `dev`, `staging` and `prod` behave identically here and differ only in the values
# you configure (URLs, secrets, groups). `local` is the developer's machine or the Docker Compose stack, which has
# no gateway and no certificates, and it allows exactly three things a deployed environment refuses:
#   1. the dev-only locally signed JWT switch, `devLocalJwtEnabled` (ADR-023, which also needs an unencrypted
#      database connection and a `http://localhost` JWKS URL);
#   2. a plain-http `gatewayJwksUrl`, to localhost or 127.0.0.1 only (`checkJwksUrl`);
#   3. a plain-http `linkedinRedirectUri`, for the local One WSO2 page (`checkRedirectUri`).
# Never set `local` on a deployed component: `scripts/check-descriptors.sh` fails if a descriptor does.
configurable string environment = "prod";
# Header the API proxy puts the backend JWT in.
configurable string jwtHeader = "x-jwt-assertion";
# Gateway JWKS URL (Choreo backend JWT signing keys).
configurable string gatewayJwksUrl = ?;
# Gateway backend JWT `iss`.
configurable string gatewayIssuer = ?;
# Accepted backend JWT `aud` values, comma separated (a string so `BAL_CONFIG_VAR_*` can set it).
configurable string gatewayAudiences = ?;
# Claim carrying Asgardeo groups.
configurable string rolesClaim = "groups";
# Email claim.
configurable string emailClaim = "email";
# Display name claim.
configurable string nameClaim = "name";
# Allowed clock skew, seconds.
configurable int clockSkewSeconds = 60;
# JWKS refresh age, seconds.
configurable decimal jwksRefreshSeconds = 3600;
# Minimum seconds between refreshes for unknown `kid` / stale keys.
configurable decimal jwksMinRefreshIntervalSeconds = 30;
# JWKS HTTP timeout, seconds.
configurable decimal jwksTimeoutSeconds = 5;
# JWKS breaker reset, seconds.
configurable decimal jwksBreakerResetSeconds = 30;

// ---- Access: Asgardeo groups per capability (modules/auth/access.bal) -----------------------------
// Each value is a comma separated list of groups (a string so `BAL_CONFIG_VAR_*` can set it); a caller
// holding any one of them has the capability. Setup: docs/runbooks/identity-setup.md.

# Groups that register, edit and archive campaigns and see every campaign status.
configurable string canCampaignGroups = "amplify_po,amplify_marketing";
# Groups that read the Dashboarding boards (ADR-036).
configurable string canDashboardGroups = "amplify_po,amplify_marketing,amplify_slt,amplify_admin";
# Groups that download the dashboard CSV export (names and emails).
configurable string canExportGroups = "amplify_po,amplify_marketing,amplify_slt,amplify_admin";
# Groups that review external shares.
configurable string canReviewSharesGroups = "amplify_po";
# Groups that manage point rules.
configurable string canPointRulesGroups = "amplify_po";
# Groups that adjust and reverse points and see anyone's team list and history.
configurable string canAdjustPointsGroups = "amplify_po";
# Groups that read the PO dashboard.
configurable string canPoDashboardGroups = "amplify_po";
# Groups that read the SLT reports (phase 2).
configurable string canReportsGroups = "amplify_slt,amplify_po";
# Groups that change settings, retry announcements and sync the scheduler.
configurable string canAdminGroups = "amplify_admin";

final auth:AccessGroups & readonly accessGroups = {
    canCampaign: auth:groupList(canCampaignGroups),
    canDashboard: auth:groupList(canDashboardGroups),
    canExport: auth:groupList(canExportGroups),
    canReviewShares: auth:groupList(canReviewSharesGroups),
    canPointRules: auth:groupList(canPointRulesGroups),
    canAdjustPoints: auth:groupList(canAdjustPointsGroups),
    canPoDashboard: auth:groupList(canPoDashboardGroups),
    canReports: auth:groupList(canReportsGroups),
    canAdmin: auth:groupList(canAdminGroups)
};

// ---- Dev-only local signing (ADR-023). Refused unless environment = "local" ---------------------

# Accept tokens signed by a local key (no API proxy). Off by default.
configurable boolean devLocalJwtEnabled = false;
# Local JWKS file with the dev public key(s).
configurable string devJwksFile = "";
# `iss` of locally signed tokens; must differ from `gatewayIssuer`.
configurable string devIssuer = "amplify-local-dev";

final auth:TokenVerifier verifier = check newVerifier();

isolated function newVerifier() returns auth:TokenVerifier|error {
    check checkDevSwitch(environment, devLocalJwtEnabled, devIssuer, gatewayIssuer, dbSslMode, gatewayJwksUrl);
    check checkJwksUrl(environment, gatewayJwksUrl);
    auth:DevTrust? dev = ();
    if devLocalJwtEnabled {
        dev = {issuer: devIssuer, keys: check auth:parseJwks(check io:fileReadJson(devJwksFile))};
        log:printError("DEV-ONLY: accepting locally signed JWTs (ADR-023). Never enable outside local Docker.",
                issuer = devIssuer);
    }
    auth:JwksCache jwks = check new ({
        url: gatewayJwksUrl,
        refreshSeconds: jwksRefreshSeconds,
        minRefreshIntervalSeconds: jwksMinRefreshIntervalSeconds,
        timeoutSeconds: jwksTimeoutSeconds,
        breakerResetSeconds: jwksBreakerResetSeconds
    });
    return new (jwks, {
        issuer: gatewayIssuer,
        audiences: from string a in re `,`.split(gatewayAudiences) where a.trim().length() > 0 select a.trim(),
        clockSkewSeconds,
        rolesClaim,
        emailClaim,
        nameClaim,
        access: accessGroups
    }, dev);
}

# Refuses a gateway JWKS URL that is not https, so signing keys never travel in the clear. A developer needs no
# certificate: plain http is accepted for `localhost` or `127.0.0.1` when `environment` is `local`, which is what the
# local stack and the tests use. Anywhere else the URL must be https.
#
# + env - `environment`
# + jwksUrl - `gatewayJwksUrl`
# + return - An error that stops startup, or `()`
isolated function checkJwksUrl(string env, string jwksUrl) returns error? {
    if jwksUrl.startsWith("https://") {
        return;
    }
    if env == "local" && isLoopbackHttp(jwksUrl) {
        return;
    }
    return error(string `gatewayJwksUrl must be https (plain http is only for localhost when environment is 'local', not '${env}')`);
}

isolated function isLoopbackHttp(string url) returns boolean {
    string prefix = "http://";
    if !url.startsWith(prefix) {
        return false;
    }
    string rest = url.substring(prefix.length());
    int end = rest.length();
    foreach string stop in ["/", ":", "?"] {
        int? at = rest.indexOf(stop);
        if at is int && at < end {
            end = at;
        }
    }
    string host = rest.substring(0, end);
    return host == "localhost" || host == "127.0.0.1";
}

# Refuses to start with the dev switch outside a local stack (ADR-023). Three independent signs of a
# local stack must all hold, so one stray environment variable on a deployed environment is not enough:
# `environment` is `local`, the database connection is unencrypted (`DISABLE`, which a real database never
# is), and the gateway JWKS URL points at `http://localhost` (a stack with no real gateway).
#
# + env - `environment`
# + enabled - `devLocalJwtEnabled`
# + localIssuer - `devIssuer`
# + realIssuer - `gatewayIssuer`
# + sslMode - `dbSslMode`
# + jwksUrl - `gatewayJwksUrl`
# + return - An error that stops startup, or `()`
isolated function checkDevSwitch(string env, boolean enabled, string localIssuer, string realIssuer,
        postgresql:SSLMode sslMode, string jwksUrl) returns error? {
    if !enabled {
        return;
    }
    if env != "local" || sslMode != postgresql:DISABLE || !jwksUrl.startsWith("http://localhost") {
        return error(string `devLocalJwtEnabled is refused outside a local stack (environment '${env}')`);
    }
    if localIssuer.trim().length() == 0 || localIssuer == realIssuer {
        return error("devIssuer must be set and differ from gatewayIssuer");
    }
}
