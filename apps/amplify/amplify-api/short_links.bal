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

import amplify_common.types;

import ballerina/http;
import ballerina/log;

// ---- LinkedIn short links (ADR-017 amendment 2026-11-26) -----------------------------------------------

# Base URL of LinkedIn's URL shortener. "Copy link to post" gives a `lnkd.in/p/<code>` link, and LinkedIn answers it
# with a 301 to the post. Empty = short links are refused as before.
configurable string linkedInShortLinkBaseUrl = "https://lnkd.in";
# Timeout for the one request a short link costs, seconds.
configurable decimal linkedInShortLinkTimeoutSeconds = 3;

final http:Client? shortLinkClient = check newShortLinkClient(linkedInShortLinkBaseUrl, linkedInShortLinkTimeoutSeconds);

isolated function newShortLinkClient(string baseUrl, decimal timeout) returns http:Client?|error {
    if baseUrl.trim() == "" {
        return ();
    }
    // Redirects are never followed: only the first answer's Location is read, and it must name a LinkedIn post.
    return check new (baseUrl.trim(), {timeout, followRedirects: {enabled: false}, httpVersion: http:HTTP_1_1});
}

# Where a short link points: the Location of LinkedIn's redirect, read with one GET and no redirect following.
# A seam the tests mock.
#
# + path - `/p/<code>` from `types:linkedInShortLinkPath`
# + return - The Location header, `()` when the answer was not a redirect, or an error when the call failed
isolated function shortLinkLocation(string path) returns string?|error {
    http:Client? c = shortLinkClient;
    if c is () {
        return ();
    }
    http:Response res = check c->get(path, {"User-Agent": "Mozilla/5.0 (compatible; Amplify)"});
    if res.statusCode < 300 || res.statusCode > 308 {
        return ();
    }
    string|http:HeaderNotFoundError location = res.getHeader("Location");
    return location is string ? location : ();
}

# The full LinkedIn post URL a short link stands for, or the URL unchanged when it is not a short link.
# The redirect target is accepted only when it parses as a LinkedIn post URL that names a post URN, so a short link
# can never smuggle in another site or a URL that would claim nothing in particular.
#
# + url - Evidence URL as sent
# + return - The URL to validate and store, or a domain error when a short link can't be resolved to a post
isolated function expandShortLink(string url) returns string|types:DomainError {
    string? path = types:linkedInShortLinkPath(url);
    if path is () {
        return url;
    }
    string?|error location = shortLinkLocation(path);
    if location is error {
        log:printError("LinkedIn short link could not be resolved", location);
    }
    if location is string {
        types:EvidenceUrl|types:DomainError target = types:parseEvidenceUrl(location);
        if target is types:EvidenceUrl && target.provider == types:EVIDENCE_PROVIDER_LINKEDIN
                && target.resourceUrn !is () {
            return location;
        }
    }
    return types:domainError(types:ERR_INVALID_EVIDENCE_URL,
            "We couldn't open that LinkedIn short link. Open it in your browser and paste the full link from the address bar");
}
