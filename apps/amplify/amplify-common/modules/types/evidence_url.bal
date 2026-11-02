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

import ballerina/lang.regexp;

# Longest evidence URL accepted, as typed and after normalization.
public const int EVIDENCE_URL_MAX_LENGTH = 2048;

# Detected provider for a LinkedIn host.
public const string EVIDENCE_PROVIDER_LINKEDIN = "linkedin";
# Detected provider for a Medium host.
public const string EVIDENCE_PROVIDER_MEDIUM = "medium";
# Detected provider for any other host.
public const string EVIDENCE_PROVIDER_OTHER = "other";

// LinkedIn's URL shortener. Never accepted as evidence (see `parseEvidenceUrl`).
const string LINKEDIN_SHORT_HOST = "lnkd.in";

// Query parameters dropped during normalization, compared lowercased. `utm_*` is handled by prefix.
final string[] & readonly TRACKING_PARAMS = ["fbclid", "gclid", "trk", "trackingid", "mc_cid", "mc_eid"];

# Evidence URL of an external share (S3), normalized for the one-claim-per-URL rule (C5, ADR-017).
# Amplify never fetches it.
public type EvidenceUrl record {|
    # Uniqueness key (`evidence_url`). For a LinkedIn URL that names a post URN it is the canonical
    # feed URL of that URN, so both LinkedIn URL forms claim one post.
    string normalized;
    # URL as the employee typed it, trimmed (`evidence_url_submitted`)
    string submitted;
    # Lowercased host (`evidence_host`)
    string host;
    # Detected provider: `linkedin`, `medium` or `other`
    string provider;
    # LinkedIn resource URN when the URL names one (`resource_urn`)
    PostUrn? resourceUrn;
|};

# Validates and normalizes an evidence URL.
#
# Rules: HTTPS only; at most 2048 characters; no user info (credentials); host must be a DNS name, not an
# IP literal or a single label like `localhost`. Normalization lowercases scheme and host, drops the
# default port, the fragment and trailing slashes, strips tracking parameters (`utm_*`, `fbclid`,
# `gclid`, `trk`, `trackingId`, `mc_cid`, `mc_eid`) and sorts the remaining query parameters.
# Path case is kept (paths are case sensitive). Percent-encoding is left as typed. A LinkedIn URL that
# names a post URN normalizes to the canonical feed URL of that URN (see `EvidenceUrl.normalized`).
#
# + raw - URL as typed
# + return - The normalized evidence URL, or a domain error
public isolated function parseEvidenceUrl(string raw) returns EvidenceUrl|DomainError {
    string submitted = raw.trim();
    if submitted.length() == 0 {
        return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL is required");
    }
    if submitted.length() > EVIDENCE_URL_MAX_LENGTH {
        return domainError(ERR_EVIDENCE_URL_TOO_LONG,
                string `Evidence URL must be at most ${EVIDENCE_URL_MAX_LENGTH} characters`);
    }
    foreach int cp in submitted.toCodePointInts() {
        if cp <= 0x20 || cp == 0x7F {
            return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL must not contain spaces or control characters");
        }
    }
    if !submitted.toLowerAscii().startsWith("https://") {
        return domainError(ERR_EVIDENCE_URL_NOT_HTTPS, "Evidence URL must start with https://");
    }

    string rest = submitted.substring(8);
    int? hashAt = rest.indexOf("#");
    if hashAt is int {
        rest = rest.substring(0, hashAt);
    }
    int authorityEnd = rest.length();
    foreach string separator in ["/", "?"] {
        int? at = rest.indexOf(separator);
        if at is int && at < authorityEnd {
            authorityEnd = at;
        }
    }
    string authority = rest.substring(0, authorityEnd);
    string pathAndQuery = rest.substring(authorityEnd);

    if authority.includes("@") {
        return domainError(ERR_EVIDENCE_URL_CREDENTIALS, "Evidence URL must not contain a user name or password");
    }
    if authority.startsWith("[") {
        return domainError(ERR_EVIDENCE_URL_IP_HOST, "Evidence URL must use a host name, not an IP address");
    }
    string host = authority;
    string port = "";
    int? colonAt = authority.lastIndexOf(":");
    if colonAt is int {
        host = authority.substring(0, colonAt);
        string portText = authority.substring(colonAt + 1);
        int|error portNumber = int:fromString(portText);
        if !re `[0-9]{1,5}`.isFullMatch(portText) || portNumber !is int || portNumber < 1 || portNumber > 65535 {
            return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL has an invalid port");
        }
        if portNumber != 443 {
            port = string `:${portNumber}`;
        }
    }
    host = host.toLowerAscii();
    if host.endsWith(".") {
        host = host.substring(0, host.length() - 1);
    }
    DomainError? hostError = validateHost(host);
    if hostError is DomainError {
        return hostError;
    }
    if host == LINKEDIN_SHORT_HOST {
        // A short link redirects to a post Amplify never fetches, so it can't be tied to the post's URN:
        // the same post could be claimed once by its short link and again by its full URL (ADR-017).
        return domainError(ERR_INVALID_EVIDENCE_URL,
                "LinkedIn short links (lnkd.in) are not accepted. Use the post's full LinkedIn URL or just its number");
    }

    string path = pathAndQuery;
    string query = "";
    int? queryAt = pathAndQuery.indexOf("?");
    if queryAt is int {
        path = pathAndQuery.substring(0, queryAt);
        query = pathAndQuery.substring(queryAt + 1);
    }
    while path.endsWith("/") {
        path = path.substring(0, path.length() - 1);
    }
    string[] kept = [];
    foreach string param in re `&`.split(query) {
        if param.length() == 0 {
            continue;
        }
        int? equalsAt = param.indexOf("=");
        string key = (equalsAt is int ? param.substring(0, equalsAt) : param).toLowerAscii();
        if key.startsWith("utm_") || TRACKING_PARAMS.indexOf(key) !is () {
            continue;
        }
        kept.push(param);
    }
    string sortedQuery = string:'join("&", ...kept.sort());

    string provider = detectProvider(host);
    PostUrn? resourceUrn = provider == EVIDENCE_PROVIDER_LINKEDIN ? linkedInResourceUrn(path) : ();
    // One claim per post (ADR-017): LinkedIn serves a post under both `/feed/update/urn:li:activity:N`
    // and `/posts/<slug>-activity-N-xyz`, so a URL that names a post URN claims it through the one
    // canonical feed URL of that URN. The URL as typed is kept in `submitted`.
    string normalized = resourceUrn is PostUrn
        ? canonicalPostUrl(resourceUrn)
        : string `https://${host}${port}${path}` + (sortedQuery.length() > 0 ? "?" + sortedQuery : "");
    return {
        normalized,
        submitted,
        host,
        provider,
        resourceUrn
    };
}

# The evidence URL for a LinkedIn post known only by its number (the activity id in
# `.../feed/update/urn:li:activity:<number>` or `.../posts/<slug>-activity-<number>-xyz`). It is the
# canonical feed URL of that URN, the same string `parseEvidenceUrl` normalizes every LinkedIn post URL to,
# so it is what is stored as the claim's evidence URL and it collides with any other form of the same post.
#
# + postNumber - The post number: digits only (surrounding spaces are ignored)
# + return - The canonical evidence URL, or a domain error when it is not a post number
public isolated function linkedInPostEvidenceUrl(string postNumber) returns string|DomainError {
    string digits = postNumber.trim();
    if !re `[0-9]+`.isFullMatch(digits) {
        return domainError(ERR_INVALID_EVIDENCE_URL, "A LinkedIn post number has digits only");
    }
    PostUrn urn = check parsePostUrn(string `urn:li:activity:${digits}`);
    return canonicalPostUrl(urn);
}

// Canonical public URL of a LinkedIn post URN: the claim key for both LinkedIn URL forms.
isolated function canonicalPostUrl(PostUrn urn) returns string =>
    string `https://www.linkedin.com/feed/update/${urn}`;

isolated function validateHost(string host) returns DomainError? {
    if host.length() == 0 || host.length() > 253 {
        return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL has no valid host");
    }
    if isIpLiteralHost(host) {
        return domainError(ERR_EVIDENCE_URL_IP_HOST, "Evidence URL must use a host name, not an IP address");
    }
    string[] labels = re `\.`.split(host);
    if labels.length() < 2 {
        return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL host must be a public domain name");
    }
    foreach string label in labels {
        if !re `[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?`.isFullMatch(label) {
            return domainError(ERR_INVALID_EVIDENCE_URL, "Evidence URL host is not a valid domain name");
        }
    }
    return ();
}

isolated function detectProvider(string host) returns string {
    if host == "linkedin.com" || host.endsWith(".linkedin.com") {
        return EVIDENCE_PROVIDER_LINKEDIN;
    }
    if host == "medium.com" || host.endsWith(".medium.com") {
        return EVIDENCE_PROVIDER_MEDIUM;
    }
    return EVIDENCE_PROVIDER_OTHER;
}

// `/feed/update/urn:li:activity:123` or `/posts/name_slug-activity-123-abcd`.
isolated function linkedInResourceUrn(string path) returns PostUrn? {
    string decoded = re `%3[Aa]`.replaceAll(path, ":");
    regexp:Groups? feed = re `/feed/update/(urn:li:[A-Za-z]+:[A-Za-z0-9_\-]+)`.findGroups(decoded);
    if feed is regexp:Groups {
        regexp:Span? span = feed[1];
        if span is regexp:Span {
            PostUrn|DomainError urn = parsePostUrn(span.substring());
            return urn is PostUrn ? urn : ();
        }
    }
    regexp:Groups? post = re `/posts/.*-activity-([0-9]+)`.findGroups(decoded);
    if post is regexp:Groups {
        regexp:Span? span = post[1];
        if span is regexp:Span {
            // Same invariant as every other PostUrn (URN_MAX_LENGTH, 100-character id).
            PostUrn|DomainError urn = parsePostUrn(string `urn:li:activity:${span.substring()}`);
            return urn is PostUrn ? urn : ();
        }
    }
    return ();
}
