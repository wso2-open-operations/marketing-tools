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

// In-memory house cache: `house_id` to a house, and employee email to `house_id`, with a time to live per entry
// (default 30 days). Reads are a map lookup under one lock and never touch the network or the database. The cache is
// per process (each amplify-api replica holds its own) and is empty after a restart: `HouseService` fills it.

import ballerina/time;

# Seconds an entry lives unless refreshed: 30 days.
const decimal DEFAULT_HOUSE_TTL_SECONDS = 2592000;

# Monotonic clock in seconds (a test seam).
type HouseClock isolated function () returns decimal;

isolated function houseMonotonic() returns decimal => time:monotonicNow();

# A cached house and when it was loaded (monotonic seconds).
type HouseEntry record {|
    # The house
    House house;
    # When it was loaded, monotonic seconds
    decimal loadedAt;
|};

# A cached assignment and when it was loaded (monotonic seconds).
type HouseAssignmentEntry record {|
    # The house id
    string houseId;
    # When it was loaded, monotonic seconds
    decimal loadedAt;
|};

# The house cache.
isolated class HouseCache {
    private final decimal ttl;
    private final HouseClock clock;
    private map<HouseEntry & readonly> houses = {};
    private map<HouseAssignmentEntry & readonly> assignments = {};
    // House id to the emails assigned to it, so a house's members are not found by scanning everyone.
    private map<string[]> members = {};

    # Creates an empty cache.
    #
    # + ttlSeconds - Seconds an entry lives unless refreshed
    # + clock - Monotonic clock, seconds (tests pass a fake)
    isolated function init(decimal ttlSeconds = DEFAULT_HOUSE_TTL_SECONDS, HouseClock clock = houseMonotonic) {
        self.ttl = ttlSeconds;
        self.clock = clock;
    }

    # A house by id.
    #
    # + houseId - The house id
    # + return - The house, or `()` when it is not cached or has expired
    isolated function getHouse(string houseId) returns House? {
        decimal now = self.clock();
        lock {
            (HouseEntry & readonly)? entry = self.houses[houseId];
            if entry is () {
                return ();
            }
            if now - entry.loadedAt >= self.ttl {
                _ = self.houses.remove(houseId);
                return ();
            }
            return entry.house;
        }
    }

    # The house id of an employee.
    #
    # + email - Work email, any case
    # + return - The house id, or `()` when the employee has none cached or it has expired
    isolated function houseIdOf(string email) returns string? {
        string key = normalizeHouseEmail(email);
        decimal now = self.clock();
        lock {
            (HouseAssignmentEntry & readonly)? entry = self.assignments[key];
            if entry is () {
                return ();
            }
            if now - entry.loadedAt >= self.ttl {
                self.dropAssignment(key);
                return ();
            }
            return entry.houseId;
        }
    }

    # The work emails assigned to a house, in no particular order.
    #
    # + houseId - The house id
    # + return - A copy of the emails (lower-case), without expired ones
    isolated function membersOf(string houseId) returns string[] {
        decimal now = self.clock();
        lock {
            string[] list = self.members[houseId] ?: [];
            string[] live = [];
            foreach string email in list {
                (HouseAssignmentEntry & readonly)? entry = self.assignments[email];
                if entry is HouseAssignmentEntry && now - entry.loadedAt < self.ttl {
                    live.push(email);
                }
            }
            return live.clone();
        }
    }

    # Puts one house, or replaces it, and restarts its time to live.
    #
    # + house - The house
    isolated function putHouse(House house) {
        decimal now = self.clock();
        (HouseEntry & readonly) entry = {house: house.cloneReadOnly(), loadedAt: now}.cloneReadOnly();
        lock {
            self.houses[house.houseId] = entry;
        }
    }

    # Puts one employee's house, or moves them, and restarts the entry's time to live.
    #
    # + email - Work email, any case. Blank is ignored.
    # + houseId - The house id
    isolated function putAssignment(string email, string houseId) {
        string key = normalizeHouseEmail(email);
        if key == "" {
            return;
        }
        decimal now = self.clock();
        (HouseAssignmentEntry & readonly) entry = {houseId, loadedAt: now}.cloneReadOnly();
        lock {
            self.dropAssignment(key);
            self.assignments[key] = entry;
            string[] list = self.members[houseId] ?: [];
            list.push(key);
            self.members[houseId] = list;
        }
    }

    # Replaces everything in one step: a reader sees the old cache or the new one, never a half-loaded one.
    #
    # + houses - Every house
    # + assignments - Every employee's house; the last row for an email wins
    isolated function replaceAll(House[] houses, HouseAssignment[] assignments) {
        decimal now = self.clock();
        map<HouseEntry & readonly> newHouses = {};
        foreach House h in houses {
            newHouses[h.houseId] = {house: h.cloneReadOnly(), loadedAt: now}.cloneReadOnly();
        }
        map<HouseAssignmentEntry & readonly> newAssignments = {};
        foreach HouseAssignment a in assignments {
            string key = normalizeHouseEmail(a.email);
            if key != "" {
                newAssignments[key] = {houseId: a.houseId, loadedAt: now}.cloneReadOnly();
            }
        }
        map<string[]> newMembers = {};
        foreach var [email, entry] in newAssignments.entries() {
            string[] list = newMembers[entry.houseId] ?: [];
            list.push(email);
            newMembers[entry.houseId] = list;
        }
        lock {
            self.houses = newHouses.clone();
            self.assignments = newAssignments.clone();
            self.members = newMembers.clone();
        }
    }

    # Removes one house. The employees assigned to it stay assigned (their house id then names no cached house).
    #
    # + houseId - The house id
    # + return - True when it was cached
    isolated function removeHouse(string houseId) returns boolean {
        lock {
            return self.houses.removeIfHasKey(houseId) is HouseEntry;
        }
    }

    # Removes one employee's house assignment.
    #
    # + email - Work email, any case
    # + return - True when it was cached
    isolated function removeAssignment(string email) returns boolean {
        string key = normalizeHouseEmail(email);
        lock {
            boolean had = self.assignments.hasKey(key);
            self.dropAssignment(key);
            return had;
        }
    }

    # Drops every entry past its time to live.
    #
    # + return - Entries dropped, houses and assignments together
    isolated function purgeExpired() returns int {
        decimal now = self.clock();
        int dropped = 0;
        lock {
            foreach var [id, entry] in self.houses.entries() {
                if now - entry.loadedAt >= self.ttl {
                    _ = self.houses.remove(id);
                    dropped += 1;
                }
            }
            string[] stale = from var [email, entry] in self.assignments.entries()
                where now - entry.loadedAt >= self.ttl
                select email;
            foreach string email in stale {
                self.dropAssignment(email);
                dropped += 1;
            }
        }
        return dropped;
    }

    # Empties the cache.
    isolated function clear() {
        lock {
            self.houses = {};
            self.assignments = {};
            self.members = {};
        }
    }

    # What the cache holds.
    #
    # + return - Counts
    isolated function stats() returns HouseCacheStats {
        lock {
            return {houses: self.houses.length(), employees: self.assignments.length()};
        }
    }

    // Removes an assignment and its place in the house's member list. Called inside a lock.
    private isolated function dropAssignment(string key) {
        lock {
            (HouseAssignmentEntry & readonly)? old = self.assignments.removeIfHasKey(key);
            if old is HouseAssignmentEntry {
                string[]? list = self.members[old.houseId];
                if list is string[] {
                    int? at = list.indexOf(key);
                    if at is int {
                        _ = list.remove(at);
                    }
                    if list.length() == 0 {
                        _ = self.members.remove(old.houseId);
                    }
                }
            }
        }
    }
}

isolated function normalizeHouseEmail(string email) returns string => email.trim().toLowerAscii();
