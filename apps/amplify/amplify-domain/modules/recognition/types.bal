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

// S4 Recognition is a read model over the C2 ledger. It publishes no events (so no events.bal); it
// consumes PointsAwarded / PointsAdjusted / PointsReversed in the producer's transaction (B12).

import amplify_common.types;

import ballerina/time;

# Period key for the all-time board.
public const string PERIOD_ALL = "ALL";
# Default `leaderboard.top_n` (B16).
public const int DEFAULT_TOP_N = 3;

# One employee's points total in a period (input to ranking).
public type EmployeeTotal record {|
    # Employee
    types:EmployeeId employeeId;
    # Display name
    string displayName;
    # Email, for the One WSO2 team lookup (ADR-009)
    string email;
    # Sum of signed ledger points
    int totalPoints;
    # Last ledger row time
    time:Utc? lastActivityAt;
|};

# One row of `recognition.standing`, ranks precomputed.
public type Standing record {|
    # `ALL`, `2026-10`, `2026-Q4`
    string periodKey;
    # Employee
    types:EmployeeId employeeId;
    # Display name
    string displayName;
    # Email
    string email;
    # Points
    int totalPoints;
    # Dense rank: ties share a rank
    int rank;
    # Rank before this re-rank (movement arrow)
    int? previousRank;
    # Points to reach the next better rank (0 at rank 1)
    int pointsToNextRank;
    # Points to enter the top N (0 when already in, leaderboards.md)
    int pointsToTopN;
    # Last activity
    time:Utc? lastActivityAt;
|};

# One person's points, for grouping by team or business unit.
public type EmailPoints record {|
    # Email, lowercase
    string email;
    # Points
    int totalPoints;
|};
