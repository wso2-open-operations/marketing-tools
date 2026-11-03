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

isolated decimal fakeNow = 1000;

isolated function now() returns decimal {
    lock {
        return fakeNow;
    }
}

isolated function advance(decimal seconds) {
    lock {
        fakeNow += seconds;
    }
}

final readonly & House OAK = {houseId: "h1", name: "Oak", imageUrl: "https://img.example/oak.png"};
final readonly & House ASH = {houseId: "h2", name: "Ash"};

// A source that can be told to fail.
isolated class FlakySource {
    *HouseSource;

    private boolean down = false;
    private int calls = 0;

    isolated function setDown(boolean down) {
        lock {
            self.down = down;
        }
    }

    isolated function callCount() returns int {
        lock {
            return self.calls;
        }
    }

    public isolated function getHouses() returns House[]|error {
        lock {
            self.calls += 1;
            if self.down {
                return error("src unavailable");
            }
        }
        return [OAK, ASH];
    }

    public isolated function getAssignments() returns HouseAssignment[]|error {
        lock {
            if self.down {
                return error("src unavailable");
            }
        }
        return [{email: "Ada@WSO2.com", houseId: "h1"}, {email: "grace@wso2.com", houseId: "h1"},
            {email: "linus@wso2.com", houseId: "h2"}];
    }
}

@test:Config {groups: ["house"]}
function testAHouseComesBackByIdWithItsNameAndImage() {
    HouseCache cache = new (clock = now);
    cache.putHouse(OAK);
    test:assertEquals(cache.getHouse("h1"), OAK);
    test:assertEquals(cache.getHouse("nope"), ());
}

@test:Config {groups: ["house"]}
function testAnEntryExpiresAfterTheTimeToLiveAndRefreshRestartsIt() {
    HouseCache cache = new (ttlSeconds = 100, clock = now);
    cache.putHouse(OAK);
    advance(99);
    test:assertEquals(cache.getHouse("h1"), OAK, "still live one second before the end");
    cache.putHouse(OAK);
    advance(99);
    test:assertEquals(cache.getHouse("h1"), OAK, "refreshing restarted the clock");
    advance(1);
    test:assertEquals(cache.getHouse("h1"), (), "expired");
}

@test:Config {groups: ["house"]}
function testTheDefaultTimeToLiveIsThirtyDays() {
    test:assertEquals(DEFAULT_HOUSE_TTL_SECONDS, 30 * 24 * 60 * 60d);
}

@test:Config {groups: ["house"]}
function testEmailsAreMatchedTrimmedAndLowerCased() {
    HouseCache cache = new (clock = now);
    cache.putAssignment("  Ada@WSO2.com ", "h1");
    test:assertEquals(cache.houseIdOf("ada@wso2.com"), "h1");
    test:assertEquals(cache.houseIdOf("ADA@wso2.COM"), "h1");
    cache.putAssignment("   ", "h1");
    test:assertEquals(cache.stats().employees, 1, "a blank email is ignored");
}

@test:Config {groups: ["house"]}
function testMovingAnEmployeeUpdatesBothHouses() {
    HouseCache cache = new (clock = now);
    cache.putAssignment("ada@wso2.com", "h1");
    cache.putAssignment("grace@wso2.com", "h1");
    cache.putAssignment("ada@wso2.com", "h2");
    test:assertEquals(cache.membersOf("h1"), ["grace@wso2.com"]);
    test:assertEquals(cache.membersOf("h2"), ["ada@wso2.com"]);
    test:assertEquals(cache.houseIdOf("ada@wso2.com"), "h2");
}

@test:Config {groups: ["house"]}
function testReplaceAllSwapsEverythingAndLastRowWins() {
    HouseCache cache = new (clock = now);
    cache.putHouse({houseId: "old", name: "Old"});
    cache.putAssignment("gone@wso2.com", "old");
    cache.replaceAll([OAK, ASH], [{email: "a@wso2.com", houseId: "h1"}, {email: "A@wso2.com", houseId: "h2"}]);
    test:assertEquals(cache.getHouse("old"), (), "what the new load lacks is gone");
    test:assertEquals(cache.houseIdOf("gone@wso2.com"), ());
    test:assertEquals(cache.houseIdOf("a@wso2.com"), "h2", "the last row for an email wins");
    test:assertEquals(cache.membersOf("h1"), [], "and the first row's membership went with it");
    test:assertEquals(cache.stats(), {houses: 2, employees: 1});
}

@test:Config {groups: ["house"]}
function testRemoveOnDemand() {
    HouseCache cache = new (clock = now);
    cache.replaceAll([OAK], [{email: "ada@wso2.com", houseId: "h1"}]);
    test:assertTrue(cache.removeAssignment("ADA@wso2.com"));
    test:assertFalse(cache.removeAssignment("ada@wso2.com"), "already gone");
    test:assertEquals(cache.membersOf("h1"), []);
    test:assertTrue(cache.removeHouse("h1"));
    test:assertFalse(cache.removeHouse("h1"));
}

@test:Config {groups: ["house"]}
function testAnExpiredAssignmentIsNotAMember() {
    HouseCache cache = new (ttlSeconds = 50, clock = now);
    cache.putAssignment("ada@wso2.com", "h1");
    advance(10);
    cache.putAssignment("grace@wso2.com", "h1");
    advance(45);
    test:assertEquals(cache.membersOf("h1"), ["grace@wso2.com"], "ada's entry is 55 s old, grace's is 45 s");
    test:assertEquals(cache.purgeExpired(), 1);
    test:assertEquals(cache.stats().employees, 1);
}

@test:Config {groups: ["house"]}
function testServicePopulatesFromTheSourceAndAnswersFromTheCache() returns error? {
    FlakySource src = new;
    HouseService svc = new (src, new HouseCache(clock = now));
    RefreshReport report = check svc.populate();
    test:assertEquals(report, {houses: 2, employees: 3});
    test:assertEquals(svc.houseOf("ADA@wso2.com"), OAK);
    test:assertEquals(svc.houseOf("linus@wso2.com")?.name, "Ash");
    test:assertEquals(svc.houseOf("nobody@wso2.com"), ());
    test:assertEquals(svc.getHouse("h2"), ASH);
    string[] members = svc.membersOf("h1");
    test:assertEquals(members.sort(), ["ada@wso2.com", "grace@wso2.com"]);
    int before = src.callCount();
    _ = svc.houseOf("ada@wso2.com");
    _ = svc.getHouse("h1");
    test:assertEquals(src.callCount(), before, "reads never call the src");
}

@test:Config {groups: ["house"]}
function testAFailedRefreshKeepsWhatIsCached() returns error? {
    FlakySource src = new;
    HouseService svc = new (src, new HouseCache(clock = now));
    _ = check svc.populate();
    src.setDown(true);
    RefreshReport|error failed = svc.refresh();
    test:assertTrue(failed is error);
    test:assertEquals(svc.houseOf("ada@wso2.com"), OAK, "the old cache is still served");
    src.setDown(false);
    test:assertEquals(check svc.refresh(), {houses: 2, employees: 3}, "and the next refresh works again");
}

@test:Config {groups: ["house"]}
function testAFailedFirstLoadLeavesTheCacheEmpty() {
    FlakySource src = new;
    src.setDown(true);
    HouseService svc = new (src, new HouseCache(clock = now));
    test:assertTrue(svc.populate() is error);
    test:assertEquals(svc.getHouse("h1"), ());
}

@test:Config {groups: ["house"]}
function testRefreshingOneHouseReloadsItOrRemovesIt() returns error? {
    HouseCache cache = new (clock = now);
    cache.putHouse({houseId: "h1", name: "Stale name"});
    cache.putHouse({houseId: "gone", name: "Gone"});
    HouseService svc = new (new FlakySource(), cache);
    test:assertEquals(check svc.refreshHouse("h1"), OAK);
    test:assertEquals(cache.getHouse("h1"), OAK);
    test:assertEquals(check svc.refreshHouse("gone"), (), "the src no longer lists it");
    test:assertEquals(cache.getHouse("gone"), ());
}

@test:Config {groups: ["house"]}
function testServiceRemovesOnDemand() returns error? {
    HouseService svc = new (new StaticHouseSource([OAK], [{email: "ada@wso2.com", houseId: "h1"}]),
            new HouseCache(clock = now));
    _ = check svc.populate();
    test:assertTrue(svc.removeEmployee("ada@wso2.com"));
    test:assertEquals(svc.houseOf("ada@wso2.com"), ());
    test:assertTrue(svc.removeHouse("h1"));
    test:assertEquals(svc.getHouse("h1"), ());
}

@test:Config {groups: ["house"]}
function testManyConcurrentReadersSeeOneConsistentCacheDuringARefresh() returns error? {
    House[] houses = from int i in 0 ..< 50 select {houseId: string `h${i}`, name: string `House ${i}`};
    HouseAssignment[] a = from int i in 0 ..< 5000 select {email: string `p${i}@wso2.com`, houseId: string `h${i % 50}`};
    HouseCache cache = new (clock = now);
    cache.replaceAll(houses, a);
    worker w1 {
        foreach int round in 0 ..< 200 {
            cache.replaceAll(houses, a);
        }
    }
    int bad = 0;
    foreach int i in 0 ..< 20000 {
        string? id = cache.houseIdOf(string `p${i % 5000}@wso2.com`);
        if id is () || cache.getHouse(id) is () {
            bad += 1;
        }
    }
    wait w1;
    test:assertEquals(bad, 0, "a reader never sees a half-loaded cache");
}
