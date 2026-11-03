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

// Houses (ADR-046). A house is a company-wide grouping that cuts across business units and teams. Amplify keeps no
// house data in its database: houses and who belongs to which come from a source that is still to be decided
// (`HouseSource`), are held in memory (`HouseCache`) and are loaded, refreshed and removed by `HouseService`.

# A house.
public type House record {|
    # The house's id, as the source gives it. Opaque to Amplify.
    string houseId;
    # The house's name
    string name;
    # URL of the house's image, `()` when it has none
    string? imageUrl = ();
|};

# One employee's house.
public type HouseAssignment record {|
    # The employee's work email. Compared trimmed and lower-cased.
    string email;
    # The house's id
    string houseId;
|};

# Where houses and house membership come from. The source of truth is undecided, so the service only depends on this.
public type HouseSource isolated object {
    # Every house.
    #
    # + return - The houses, or an error when the source cannot answer
    public isolated function getHouses() returns House[]|error;

    # Every employee's house.
    #
    # + return - One row per employee that has a house, or an error when the source cannot answer
    public isolated function getAssignments() returns HouseAssignment[]|error;
};

# What a load put in the cache.
public type RefreshReport record {|
    # Houses loaded
    int houses;
    # Employees with a house loaded
    int employees;
|};

# What the cache holds.
public type CacheStats record {|
    # Houses held, expired ones included until they are looked up or purged
    int houses;
    # Employees with a house held
    int employees;
|};
