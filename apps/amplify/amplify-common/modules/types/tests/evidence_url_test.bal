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

import ballerina/test;

function normalizationCases() returns map<[string, string]> => {
    "lowercaseSchemeAndHost": ["HTTPS://WWW.Example.COM/Blog/Post", "https://www.example.com/Blog/Post"],
    "stripTrailingSlash": ["https://example.com/blog/post/", "https://example.com/blog/post"],
    "stripRootSlash": ["https://example.com/", "https://example.com"],
    "stripUtm": ["https://example.com/p?utm_source=x&utm_Medium=y&id=7", "https://example.com/p?id=7"],
    "stripClickIds": ["https://example.com/p?fbclid=1&gclid=2&trk=3&trackingId=4&a=b", "https://example.com/p?a=b"],
    "sortQuery": ["https://example.com/p?z=1&a=2&m=3", "https://example.com/p?a=2&m=3&z=1"],
    "dropFragment": ["https://example.com/p#comments", "https://example.com/p"],
    "dropDefaultPort": ["https://example.com:443/p", "https://example.com/p"],
    "keepOtherPort": ["https://example.com:8443/p", "https://example.com:8443/p"],
    "trailingDotHost": ["https://example.com./p", "https://example.com/p"],
    "onlyTrackingQuery": ["https://medium.com/@wso2/post-1a2b/?utm_campaign=x", "https://medium.com/@wso2/post-1a2b"],
    "trimmed": ["  https://example.com/p  ", "https://example.com/p"]
};

@test:Config {dataProvider: normalizationCases}
function evidenceUrlIsNormalized(string raw, string expected) returns error? {
    EvidenceUrl url = check parseEvidenceUrl(raw);
    test:assertEquals(url.normalized, expected);
    test:assertEquals(url.submitted, raw.trim());
}

// Regression (PR #102 review): one LinkedIn post has several URLs, and the key must not depend on which one was typed.
@test:Config
function linkedInPostUrlFormsShareOneKey() returns error? {
    string[] forms = [
        "https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd",
        "https://linkedin.com/posts/avery_wso2-activity-7123456789-AbCd",
        "https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd?x=1",
        "https://www.linkedin.com/feed/update/urn:li:activity:7123456789",
        "https://linkedin.com/feed/update/urn:li:activity:7123456789/?x=1",
        "https://www.linkedin.com/feed/update/urn%3Ali%3Aactivity%3A7123456789"
    ];
    foreach string form in forms {
        EvidenceUrl url = check parseEvidenceUrl(form);
        test:assertEquals(url.normalized, "https://www.linkedin.com/feed/update/urn:li:activity:7123456789", form);
        test:assertEquals(url.submitted, form);
    }
    EvidenceUrl other = check parseEvidenceUrl("https://www.linkedin.com/posts/avery_wso2-activity-7123456790-AbCd");
    test:assertNotEquals(other.normalized, "https://www.linkedin.com/feed/update/urn:li:activity:7123456789");
}

@test:Config
function sameLinkTypedTwoWaysNormalizesToOneKey() returns error? {
    EvidenceUrl a = check parseEvidenceUrl("https://www.LinkedIn.com/posts/avery_wso2-activity-7123456789-AbCd/?utm_source=share&utm_medium=member_desktop");
    EvidenceUrl b = check parseEvidenceUrl("https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd");
    test:assertEquals(a.normalized, b.normalized);
}

// ADR-017 one claim per post: LinkedIn serves a post at both URL forms, so the claim key must be the
// post URN's canonical feed URL, not the normalized URL as typed. Otherwise two people (or one person
// twice) claim the same post under its two URLs and both get paid.
@test:Config
function onePostHasOneClaimKeyAcrossLinkedInUrlForms() returns error? {
    string expected = "https://www.linkedin.com/feed/update/urn:li:activity:7123456789";
    foreach string raw in [
        "https://www.linkedin.com/feed/update/urn:li:activity:7123456789/",
        "https://www.linkedin.com/feed/update/urn%3Ali%3Aactivity%3A7123456789",
        "https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd",
        "https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd/?utm_source=share&trk=public_post",
        "https://de.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd"
    ] {
        EvidenceUrl url = check parseEvidenceUrl(raw);
        test:assertEquals(url.normalized, expected, raw);
        test:assertEquals(url.resourceUrn, "urn:li:activity:7123456789", raw);
        test:assertEquals(url.submitted, raw, raw);
    }
}

// A LinkedIn URL that names no post URN is not a post claim: it keeps the ordinary URL normalization.
@test:Config
function linkedInUrlsWithoutAPostUrnKeepUrlNormalization() returns error? {
    EvidenceUrl company = check parseEvidenceUrl("https://www.linkedin.com/company/wso2/?utm_source=x");
    test:assertEquals(company.normalized, "https://www.linkedin.com/company/wso2");
    test:assertEquals(company.resourceUrn, ());
}

// A lnkd.in short link can't be tied to a post URN without fetching it, so one post could be claimed
// twice (once by its short link, once by its full URL). Rejected in every form.
@test:Config
function lnkdInShortLinksAreRejected() {
    foreach string url in ["https://lnkd.in/eAbCdEf", "https://LNKD.IN/eAbCdEf/", "https://lnkd.in:443/eAbCdEf?utm_source=x",
            "https://lnkd.in/posts/x-activity-42-z"] {
        EvidenceUrl|DomainError r = parseEvidenceUrl(url);
        test:assertTrue(r is DomainError, url);
        if r is DomainError {
            test:assertEquals(r.detail().code, ERR_INVALID_EVIDENCE_URL, url);
        }
    }
    // Only that host: lookalikes are ordinary hosts.
    test:assertTrue(parseEvidenceUrl("https://notlnkd.in/x") is EvidenceUrl);
}

@test:Config
function linkedInPostNumberBuildsTheCanonicalEvidenceUrl() returns error? {
    string url = check linkedInPostEvidenceUrl(" 7123456789012345678 ");
    test:assertEquals(url, "https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345678");
    EvidenceUrl parsed = check parseEvidenceUrl(url);
    test:assertEquals(parsed.normalized, url, "already canonical");
    test:assertEquals(parsed.submitted, url);
    test:assertEquals(parsed.resourceUrn, "urn:li:activity:7123456789012345678");
    EvidenceUrl full = check parseEvidenceUrl(
            "https://www.linkedin.com/posts/avery_x-activity-7123456789012345678-AbCd?utm_source=share");
    test:assertEquals(full.normalized, parsed.normalized, "the number and the full URL claim the same post");
}

@test:Config
function linkedInPostNumberMustBeDigits() {
    foreach string bad in ["", "  ", "abc", "12a", "-5", "1.5", "urn:li:activity:123", "https://www.linkedin.com/x", "٣٤"] {
        string|DomainError r = linkedInPostEvidenceUrl(bad);
        test:assertTrue(r is DomainError, bad);
    }
    string tooLong = "".padEnd(300, "7");
    test:assertTrue(linkedInPostEvidenceUrl(tooLong) is DomainError, "an id longer than a URN allows");
}

function rejectedUrls() returns map<[string, string]> => {
    "http": ["http://example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "ftp": ["ftp://example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "javascript": ["javascript:alert(1)", ERR_EVIDENCE_URL_NOT_HTTPS],
    "noScheme": ["example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "blank": ["   ", ERR_INVALID_EVIDENCE_URL],
    "credentials": ["https://user:pass@example.com/p", ERR_EVIDENCE_URL_CREDENTIALS],
    "userOnly": ["https://user@example.com/p", ERR_EVIDENCE_URL_CREDENTIALS],
    "ipv4": ["https://10.0.0.1/admin", ERR_EVIDENCE_URL_IP_HOST],
    "ipv4Public": ["https://8.8.8.8", ERR_EVIDENCE_URL_IP_HOST],
    "ipv6": ["https://[::1]/p", ERR_EVIDENCE_URL_IP_HOST],
    "decimalIp": ["https://2130706433/p", ERR_EVIDENCE_URL_IP_HOST],
    "localhost": ["https://localhost/p", ERR_INVALID_EVIDENCE_URL],
    "badPort": ["https://example.com:99999/p", ERR_INVALID_EVIDENCE_URL],
    "space": ["https://example.com/a b", ERR_INVALID_EVIDENCE_URL],
    "badLabel": ["https://-bad-.com/p", ERR_INVALID_EVIDENCE_URL],
    "emptyHost": ["https:///p", ERR_INVALID_EVIDENCE_URL]
};

@test:Config {dataProvider: rejectedUrls}
function evidenceUrlRejects(string raw, string code) {
    test:assertEquals(codeOf(parseEvidenceUrl(raw)), code);
}

@test:Config
function evidenceUrlLengthCap() {
    string path = "";
    foreach int i in 0 ..< EVIDENCE_URL_MAX_LENGTH {
        path += "a";
    }
    test:assertEquals(codeOf(parseEvidenceUrl("https://example.com/" + path)), ERR_EVIDENCE_URL_TOO_LONG);
    string ok = "https://example.com/" + path.substring(0, EVIDENCE_URL_MAX_LENGTH - 20);
    test:assertEquals(codeOf(parseEvidenceUrl(ok)), "OK");
}

@test:Config
function evidenceProviderAndUrnAreDetected() returns error? {
    EvidenceUrl feed = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn:li:activity:7123456789/");
    test:assertEquals(feed.provider, EVIDENCE_PROVIDER_LINKEDIN);
    test:assertEquals(feed.host, "www.linkedin.com");
    test:assertEquals(feed.resourceUrn, "urn:li:activity:7123456789");

    EvidenceUrl encoded = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn%3Ali%3Ashare%3A42");
    test:assertEquals(encoded.resourceUrn, "urn:li:share:42");

    EvidenceUrl post = check parseEvidenceUrl("https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd");
    test:assertEquals(post.resourceUrn, "urn:li:activity:7123456789");

    EvidenceUrl medium = check parseEvidenceUrl("https://wso2.medium.com/some-post");
    test:assertEquals(medium.provider, EVIDENCE_PROVIDER_MEDIUM);
    test:assertEquals(medium.resourceUrn, ());

    EvidenceUrl blog = check parseEvidenceUrl("https://blog.example.org/x");
    test:assertEquals(blog.provider, EVIDENCE_PROVIDER_OTHER);
}

@test:Config
function httpsUrlCheck() {
    test:assertTrue(isHttpsUrl("https://wso2.com/x.png"));
    test:assertFalse(isHttpsUrl("http://wso2.com/x.png"));
    test:assertFalse(isHttpsUrl("https://"));
    test:assertFalse(isHttpsUrl("https://a b"));
    // Regression (PR #102 review): `.` does not match a line break, so CR and LF used to slip through.
    test:assertFalse(isHttpsUrl("https://wso2.com/x.png\r\nSet-Cookie: a=b"));
    test:assertFalse(isHttpsUrl("https://wso2.com/a\n\nb"));
    test:assertFalse(isHttpsUrl("https://wso2.com/x.png\n"));
    test:assertFalse(isHttpsUrl("https://wso2.com/a\tb"));
}

// Regression (deep review RC-02): the `/posts/...-activity-N` branch built a PostUrn without
// `parsePostUrn`, so a 300-digit id broke the URN invariant (255 characters, 100-character id).
@test:Config
function evidencePostsUrnKeepsTheUrnInvariant() returns error? {
    string digits = "";
    foreach int i in 0 ..< 300 {
        digits += "7";
    }
    EvidenceUrl long = check parseEvidenceUrl(string `https://www.linkedin.com/posts/avery_x-activity-${digits}-AbCd`);
    test:assertEquals(long.resourceUrn, (), "an id longer than a URN allows is not a resource URN");
    EvidenceUrl short = check parseEvidenceUrl("https://www.linkedin.com/posts/x-activity-42-z");
    test:assertEquals(short.provider, EVIDENCE_PROVIDER_LINKEDIN);
    test:assertEquals(short.resourceUrn, "urn:li:activity:42");
    EvidenceUrl other = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn:li:person:abc");
    test:assertEquals(other.resourceUrn, (), "a person URN is not a post");
}

@test:Config
function evidenceUrlPortAndHostEdges() returns error? {
    EvidenceUrl port = check parseEvidenceUrl("https://Example.COM.:8443/a/");
    test:assertEquals(port.normalized, "https://example.com:8443/a");
    EvidenceUrl defaultPort = check parseEvidenceUrl("https://example.com:443?b=2&a=1&utm_source=x");
    test:assertEquals(defaultPort.normalized, "https://example.com?a=1&b=2");
    foreach string bad in ["https://example.com:0/", "https://example.com:65536/", "https://example.com:/",
            "https://exa_mple.com/", "https://-a.com/", "https://0x7f000001/", "https://a..com/"] {
        test:assertTrue(parseEvidenceUrl(bad) is DomainError, bad);
    }
}
