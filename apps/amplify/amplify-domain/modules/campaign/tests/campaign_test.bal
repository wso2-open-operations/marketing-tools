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

import amplify_common.events;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

const string WSO2_ORG = "urn:li:organization:1477";
final time:Utc T0 = [1790000000, 0];
final CampaignPolicy POLICY = {wso2OrganizationUrn: WSO2_ORG};

isolated class InMemoryCampaigns {
    *CampaignRepository;
    private map<Campaign> rows = {};
    private events:OutboxEvent[] outbox = [];
    private string[] active = [];

    # Records "a share exists" for a campaign.
    #
    # + id - Campaign id
    public isolated function markActive(string id) {
        lock {
            self.active.push(id);
        }
    }

    public isolated function hasActivity(string id, string resourceUrn) returns boolean|error {
        lock {
            return self.active.indexOf(id) !is ();
        }
    }

    public isolated function findById(string id) returns Campaign|error? {
        lock {
            return self.rows[id].clone();
        }
    }

    public isolated function findByResource(types:Provider provider, types:PostUrn resourceUrn) returns Campaign|error? {
        lock {
            foreach Campaign c in self.rows {
                if c.provider == provider && c.resourceUrn == resourceUrn {
                    return c.clone();
                }
            }
            return ();
        }
    }

    public isolated function insert(Campaign campaign, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[campaign.id] = campaign.clone();
            self.outbox.push(...outbox.clone());
        }
    }

    public isolated function update(Campaign campaign, int expectedVersion) returns error? {
        lock {
            Campaign? stored = self.rows[campaign.id];
            if stored is () || stored.version != expectedVersion {
                return types:domainError(types:ERR_VERSION_CONFLICT, "stale");
            }
            self.rows[campaign.id] = campaign.clone();
        }
    }

    public isolated function events() returns events:OutboxEvent[] {
        lock {
            return self.outbox.clone();
        }
    }
}

function draft() returns CampaignDraft => {
    resourceUrn: "urn:li:share:7123",
    ownerUrn: WSO2_ORG,
    title: "  WSO2 named a Leader  ",
    categoryCode: "PRODUCT",
    tags: ["AI", "ai", " Integration ", ""],
    imageUrl: "https://media.wso2.com/a.png"
};

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

@test:Config
function newCampaignAppliesDefaultsAndNormalizes() returns error? {
    Campaign c = check newCampaign(draft(), POLICY, "id-1", "mkt-1", T0);
    test:assertEquals(c.title, "WSO2 named a Leader");
    test:assertEquals(c.tags, ["ai", "integration"]);
    test:assertEquals(c.resourceType, types:SHARE);
    test:assertEquals(c.opensAt, T0, "opens now by default");
    test:assertEquals(c.closesAt, types:addDays(T0, 30), "C7: closes_at = opens_at + 30 days");
    test:assertEquals(c.version, 1);
}

@test:Config
function defaultWindowComesFromPolicy() returns error? {
    Campaign c = check newCampaign(draft(), {wso2OrganizationUrn: WSO2_ORG, defaultWindowDays: 7}, "id", "m", T0);
    test:assertEquals(c.closesAt, types:addDays(T0, 7));
}

@test:Config
function campaignMustBeOnTheWso2Page() {
    CampaignDraft d = draft();
    d.ownerUrn = "urn:li:organization:999";
    test:assertEquals(code(newCampaign(d, POLICY, "id", "m", T0)), types:ERR_NOT_WSO2_RESOURCE);
}

@test:Config
function campaignRejectsBadInput() {
    CampaignDraft badUrn = draft();
    badUrn.resourceUrn = "https://linkedin.com/x";
    test:assertEquals(code(newCampaign(badUrn, POLICY, "id", "m", T0)), types:ERR_INVALID_POST_URN);
    CampaignDraft noTitle = draft();
    noTitle.title = "  ";
    test:assertEquals(code(newCampaign(noTitle, POLICY, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
    CampaignDraft httpImage = draft();
    httpImage.imageUrl = "http://x.com/a.png";
    test:assertEquals(code(newCampaign(httpImage, POLICY, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
    CampaignDraft noCategory = draft();
    noCategory.categoryCode = "";
    test:assertEquals(code(newCampaign(noCategory, POLICY, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
}

@test:Config
function closesMustBeAfterOpens() {
    CampaignDraft d = draft();
    d.opensAt = T0;
    d.closesAt = T0;
    test:assertEquals(code(newCampaign(d, POLICY, "id", "m", T0)), types:ERR_INVALID_WINDOW);
    d.closesAt = types:addDays(T0, -1);
    test:assertEquals(code(newCampaign(d, POLICY, "id", "m", T0)), types:ERR_INVALID_WINDOW);
}

@test:Config
function statusIsDerivedFromFactsAndClock() returns error? {
    CampaignDraft d = draft();
    d.opensAt = types:addDays(T0, 1);
    d.closesAt = types:addDays(T0, 3);
    Campaign c = check newCampaign(d, POLICY, "id", "m", T0);
    test:assertEquals(campaignStatus(c, T0), SCHEDULED);
    test:assertEquals(campaignStatus(c, types:addDays(T0, 1)), OPEN, "open at opens_at");
    test:assertEquals(campaignStatus(c, types:addDays(T0, 2)), OPEN);
    test:assertEquals(campaignStatus(c, types:addDays(T0, 3)), CLOSED, "closed at closes_at");
    Campaign archived = check archive(c, types:addDays(T0, 2));
    test:assertEquals(campaignStatus(archived, types:addDays(T0, 2)), ARCHIVED, "archive wins over the window");
    test:assertFalse(isOpen(archived, types:addDays(T0, 2)));
}

@test:Config
function registerIsUniquePerResourceAndQueuesAnnouncement() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", true, T0);
    test:assertEquals(check types:parseUuidV7(c.id), c.id);
    events:OutboxEvent[] outbox = repo.events();
    test:assertEquals(outbox.length(), 1);
    test:assertEquals(outbox[0].eventType, events:CAMPAIGN_REGISTERED);
    test:assertEquals(outbox[0].idempotencyKey, "CampaignRegistered:" + c.id);
    test:assertEquals((<events:CampaignRegistered>outbox[0].payload).shareNow, true);

    Campaign|error again = registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    test:assertEquals(code(again), types:ERR_CAMPAIGN_ALREADY_REGISTERED);
    test:assertEquals(repo.events().length(), 1, "announced exactly once");
}

@test:Config
function editBumpsVersionAndRechecksWindow() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    Campaign edited = check updateCampaign(repo, c.id, 1, {title: "New title", tags: ["X"]}, T0);
    test:assertEquals(edited.title, "New title");
    test:assertEquals(edited.tags, ["x"]);
    test:assertEquals(edited.version, 2);
    test:assertEquals(edited.resourceUrn, c.resourceUrn, "resource can't change");
    test:assertEquals(code(updateCampaign(repo, c.id, 2, {closesAt: types:addDays(T0, -1)}, T0)), types:ERR_INVALID_WINDOW);
    test:assertEquals(code(updateCampaign(repo, "missing", 1, {}, T0)), types:ERR_NOT_FOUND);
}

@test:Config
function openedCampaignFreezesItsStart() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    time:Utc later = types:addDays(T0, 1);
    test:assertTrue(isOpen(c, later));
    test:assertEquals(code(applyPatch(c, {opensAt: types:addDays(T0, 7)}, later)), types:ERR_INVALID_WINDOW);
    test:assertEquals(code(applyPatch(c, {opensAt: types:addDays(T0, -1)}, later)), types:ERR_INVALID_WINDOW);
    // A form that sends the stored start back, with a new end, still works.
    Campaign extended = check applyPatch(c, {opensAt: c.opensAt, closesAt: types:addDays(T0, 60)}, later);
    test:assertEquals(extended.opensAt, c.opensAt);
    test:assertEquals(extended.closesAt, types:addDays(T0, 60));
}

@test:Config
function scheduledCampaignCanStillMoveItsStart() returns error? {
    InMemoryCampaigns repo = new;
    CampaignDraft d = draft();
    d.opensAt = types:addDays(T0, 3);
    Campaign c = check registerCampaign(repo, d, POLICY, "mkt-1", false, T0);
    Campaign moved = check applyPatch(c, {opensAt: types:addDays(T0, 4)}, T0);
    test:assertEquals(moved.opensAt, types:addDays(T0, 4));
}

@test:Config
function staleEditIsAVersionConflict() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    _ = check updateCampaign(repo, c.id, 1, {title: "A"}, T0);
    Campaign stale = check applyPatch(c, {title: "B"}, T0);
    test:assertEquals(code(repo.update(stale, c.version)), types:ERR_VERSION_CONFLICT);
    // The use case checks the version the editor saw, not the one it just read.
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {title: "B"}, T0)), types:ERR_VERSION_CONFLICT);
    Campaign? stored = check repo.findById(c.id);
    test:assertEquals((<Campaign>stored).title, "A", "the stale edit changed nothing");
    test:assertEquals((<Campaign>stored).version, 2);
}

@test:Config
function deleteArchivesAndArchivedIsFrozen() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    Campaign archived = check archiveCampaign(repo, c.id, types:addDays(T0, 1));
    test:assertEquals(archived.archivedAt, types:addDays(T0, 1));
    test:assertTrue(check repo.findById(c.id) is Campaign, "soft delete keeps the row");
    test:assertEquals(code(archiveCampaign(repo, c.id, T0)), types:ERR_CAMPAIGN_ARCHIVED);
    test:assertEquals(code(updateCampaign(repo, c.id, 2, {title: "x"}, T0)), types:ERR_CAMPAIGN_ARCHIVED);
}

@test:Config
function testPostLinkMustBeLinkedIn() returns error? {
    CampaignDraft d = draft();
    foreach string ok in ["https://www.linkedin.com/feed/update/urn:li:share:7123/",
            "https://LinkedIn.com/posts/wso2_x-activity-1-y", "  https://www.linkedin.com/posts/a  "] {
        d.resourceUrl = ok;
        Campaign c = check newCampaign(d, POLICY, "id", "m", T0);
        test:assertEquals(c.resourceUrl, ok.trim(), ok);
    }
    foreach string bad in ["https://evil.example/?x=urn:li:share:1", "https://www.linkedin.com.evil.example/p",
            "https://www.linkedin.com@evil.example/p", "http://www.linkedin.com/feed/update/urn:li:share:1",
            "javascript:alert(1)", "urn:li:share:7123", "https://www.linkedin.com/posts/a b"] {
        d.resourceUrl = bad;
        test:assertEquals(code(newCampaign(d, POLICY, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN, bad);
    }
    d.resourceUrl = ();
    test:assertEquals((check newCampaign(d, POLICY, "id", "m", T0)).resourceUrl, (), "a link is optional");
}

@test:Config
function testPostLinkOriginsAreConfigurable() returns error? {
    // Dev and demos: the mock LinkedIn's origin is allowed only where it's listed.
    CampaignDraft d = draft();
    d.resourceUrl = "http://localhost:19091/feed/update/urn:li:share:7123/";
    test:assertEquals(code(newCampaign(d, POLICY, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
    CampaignPolicy withMock = {wso2OrganizationUrn: WSO2_ORG,
        postLinkOrigins: [...DEFAULT_POST_LINK_ORIGINS, "http://localhost:19091"]};
    test:assertEquals((check newCampaign(d, withMock, "id", "m", T0)).resourceUrl, d.resourceUrl);
    // The database's check (V019) only ever holds that one http origin; the app policy is what keeps production
    // https-only, so any other plain-http origin stays refused even when the mock's origin is listed.
    d.resourceUrl = "http://localhost:9091/feed/update/urn:li:share:7123/";
    test:assertEquals(code(newCampaign(d, withMock, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
    d.resourceUrl = "http://localhost:19091.evil.example/feed/update/urn:li:share:7123/";
    test:assertEquals(code(newCampaign(d, withMock, "id", "m", T0)), types:ERR_INVALID_CAMPAIGN);
}

@test:Config
function testFieldsAreCheckedAgainstWhatTheDatabaseAccepts() {
    // Each of these would otherwise reach INSERT and fail a CHECK there as a raw 23514 (a 500).
    test:assertTrue(validCategory("product") is types:DomainError, "category codes are upper case");
    test:assertTrue(validCategory("PRODUCT") is string);
    test:assertTrue(validSummary(string:'join("", ...from int i in 0 ..< 2001 select "a")) is types:DomainError);
    test:assertEquals(validSummary("  short  "), "short");
    test:assertEquals(validSummary("   "), ());
    test:assertTrue(normalizeTags(["Ärger"]) is types:DomainError, "lower-casing is ASCII only");
    test:assertTrue(normalizeTags(["café"]) is types:DomainError, "accented letters never reach the CHECK");
    test:assertTrue(normalizeTags(["ÄRGER"]) is types:DomainError, "an upper-case non-ASCII letter too");
    test:assertEquals(normalizeTags(["Ballerina", " it "]), ["ballerina", "it"]);
}

// ---- Editing the post link and id ------------------------------------------------------------------

@test:Config
function postIdChangesWhileThereIsNoActivity() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    Campaign edited = check updateCampaign(repo, c.id, 1, {
        resourceUrn: "urn:li:ugcPost:555",
        resourceUrl: "https://www.linkedin.com/feed/update/urn:li:ugcPost:555"
    }, T0);
    test:assertEquals(edited.resourceUrn, "urn:li:ugcPost:555");
    test:assertEquals(edited.resourceType, types:UGC_POST, "the type follows the id");
    test:assertEquals(edited.resourceUrl, "https://www.linkedin.com/feed/update/urn:li:ugcPost:555");
    test:assertEquals(edited.version, 2);
    Campaign? stored = check repo.findById(c.id);
    test:assertEquals((<Campaign>stored).resourceUrn, "urn:li:ugcPost:555");
}

@test:Config
function postIdIsFrozenOnceThereIsActivity() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    repo.markActive(c.id);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrn: "urn:li:share:999"}, T0)),
            types:ERR_POST_HAS_ACTIVITY);
    Campaign? stored = check repo.findById(c.id);
    test:assertEquals((<Campaign>stored).resourceUrn, c.resourceUrn, "nothing changed");
    test:assertEquals((<Campaign>stored).version, 1);
}

@test:Config
function linkAloneChangesEvenWithActivity() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    repo.markActive(c.id);
    string link = "https://www.linkedin.com/posts/wso2_new-link";
    Campaign edited = check updateCampaign(repo, c.id, 1, {resourceUrl: link, title: "Retitled"}, T0);
    test:assertEquals(edited.resourceUrl, link);
    test:assertEquals(edited.resourceUrn, c.resourceUrn);
    // Resending the stored id is not a change.
    Campaign same = check updateCampaign(repo, c.id, 2, {resourceUrn: c.resourceUrn, resourceUrl: link}, T0);
    test:assertEquals(same.version, 3);
}

@test:Config
function postIdOfAnotherCampaignIsTheRegistrationConflict() returns error? {
    InMemoryCampaigns repo = new;
    Campaign a = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    CampaignDraft other = draft();
    other.resourceUrn = "urn:li:share:8888";
    Campaign b = check registerCampaign(repo, other, POLICY, "mkt-1", false, T0);
    test:assertEquals(code(updateCampaign(repo, b.id, 1, {resourceUrn: a.resourceUrn}, T0)),
            types:ERR_CAMPAIGN_ALREADY_REGISTERED);
}

@test:Config
function postIdAndLinkGetTheRegistrationChecks() returns error? {
    InMemoryCampaigns repo = new;
    Campaign c = check registerCampaign(repo, draft(), POLICY, "mkt-1", false, T0);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrn: "urn:li:person:abc"}, T0)), types:ERR_INVALID_POST_URN);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrn: ""}, T0)), types:ERR_INVALID_POST_URN);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrl: "https://evil.example/x"}, T0)), types:ERR_INVALID_CAMPAIGN);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrl: "https://user@www.linkedin.com/x"}, T0)),
            types:ERR_INVALID_CAMPAIGN);
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrl: "https://www.linkedin.com/" + "a".padEnd(3000, "a")}, T0)),
            types:ERR_INVALID_CAMPAIGN);
    // The configured origins apply to the edit too.
    test:assertEquals(code(updateCampaign(repo, c.id, 1, {resourceUrl: "http://localhost:19091/p"}, T0)), types:ERR_INVALID_CAMPAIGN);
    Campaign ok = check updateCampaign(repo, c.id, 1, {resourceUrl: "http://localhost:19091/p"}, T0,
            [...DEFAULT_POST_LINK_ORIGINS, "http://localhost:19091"]);
    test:assertEquals(ok.resourceUrl, "http://localhost:19091/p");
}
