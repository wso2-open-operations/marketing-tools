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

// House service (ADR-046): fills the house cache from a `HouseSource` on start-up, refreshes it (the scheduler
// triggers this), and removes records on demand. A failed refresh keeps what is cached: houses change rarely, so an
// outage in the source is only felt when nothing was ever loaded.

import ballerina/log;

# Loads, refreshes and removes cached houses.
public isolated class HouseService {
    private final HouseSource src;
    private final HouseCache cache;
    private boolean refreshing = false;

    # Creates the service.
    #
    # + src - Where houses and house membership come from
    # + cache - The cache it fills and serves from
    public isolated function init(HouseSource src, HouseCache cache) {
        self.src = src;
        self.cache = cache;
    }

    # Fills the cache at start-up.
    #
    # + return - What was loaded, or an error (the cache stays empty and the caller decides whether to start anyway)
    public isolated function populate() returns RefreshReport|error => self.refresh();

    # Reloads every house and every assignment, replacing the cache in one step. One refresh runs at a time: a second
    # call while one is running is refused, not queued. A failure keeps the cached houses.
    #
    # + return - What was loaded, or an error
    public isolated function refresh() returns RefreshReport|error {
        lock {
            if self.refreshing {
                return error("A house refresh is already running");
            }
            self.refreshing = true;
        }
        RefreshReport|error report = self.load();
        lock {
            self.refreshing = false;
        }
        if report is error {
            // The source's message names no one (a source must keep it that way); nothing else is logged.
            log:printWarn("House refresh failed; keeping the cached houses", reason = report.message());
        } else {
            log:printInfo("Houses loaded", houses = report.houses, employees = report.employees);
        }
        return report;
    }

    isolated function load() returns RefreshReport|error {
        House[] houses = check self.src.getHouses();
        HouseAssignment[] assignments = check self.src.getAssignments();
        self.cache.replaceAll(houses, assignments);
        return {houses: houses.length(), employees: self.cache.stats().employees};
    }

    # Reloads one house from the source. A house the source no longer lists is removed from the cache.
    #
    # + houseId - The house id
    # + return - The house, `()` when the source has no such house, or an error
    public isolated function refreshHouse(string houseId) returns House?|error {
        House[] houses = check self.src.getHouses();
        foreach House h in houses {
            if h.houseId == houseId {
                self.cache.putHouse(h);
                return h;
            }
        }
        _ = self.cache.removeHouse(houseId);
        return ();
    }

    # A house by id, from the cache only.
    #
    # + houseId - The house id
    # + return - The house, or `()` when it is not cached
    public isolated function getHouse(string houseId) returns House? => self.cache.getHouse(houseId);

    # An employee's house, from the cache only.
    #
    # + email - Work email, any case
    # + return - The house, or `()` when the employee has none or the house is not cached
    public isolated function houseOf(string email) returns House? {
        string? houseId = self.cache.houseIdOf(email);
        return houseId is string ? self.cache.getHouse(houseId) : ();
    }

    # The work emails assigned to a house, from the cache only.
    #
    # + houseId - The house id
    # + return - The emails, lower-case
    public isolated function membersOf(string houseId) returns string[] => self.cache.membersOf(houseId);

    # Removes one house from the cache.
    #
    # + houseId - The house id
    # + return - True when it was cached
    public isolated function removeHouse(string houseId) returns boolean => self.cache.removeHouse(houseId);

    # Removes one employee's house from the cache.
    #
    # + email - Work email, any case
    # + return - True when it was cached
    public isolated function removeEmployee(string email) returns boolean => self.cache.removeAssignment(email);
}

# A `HouseSource` that answers from lists it is given: for the local stack and tests, until the real source is chosen.
public isolated class StaticHouseSource {
    *HouseSource;

    private final House[] & readonly houses;
    private final HouseAssignment[] & readonly assignments;

    # Creates the source.
    #
    # + houses - The houses it lists
    # + assignments - The assignments it lists
    public isolated function init(House[] houses = [], HouseAssignment[] assignments = []) {
        self.houses = houses.cloneReadOnly();
        self.assignments = assignments.cloneReadOnly();
    }

    # Every house.
    #
    # + return - The houses
    public isolated function getHouses() returns House[]|error => [...self.houses];

    # Every employee's house.
    #
    # + return - The assignments
    public isolated function getAssignments() returns HouseAssignment[]|error => [...self.assignments];
}
