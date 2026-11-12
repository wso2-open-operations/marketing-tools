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

// Pacing of LinkedIn posts per employee. Sharing every open campaign at once, by hand or by a script, queues
// them all; the Run then posts one, and each next one only after `publishGapSeconds` plus a little jitter. Points
// come with each post, so nobody's points grow faster than anyone else's, and LinkedIn doesn't see a burst of
// posts from one member, at exact intervals, that looks automated.

import ballerina/time;

# Seconds a share must still wait so the employee's posts stay at least `gapSeconds` apart, plus up to
# `jitterSeconds` so they don't land at exact intervals. 0 when it can go now.
#
# + lastPublished - When the employee's latest share was published, `()` if none was
# + now - Current time
# + gapSeconds - Least time between two of the employee's posts; 0 or less turns pacing off
# + jitterSeconds - Most extra wait
# + seed - Varies the jitter (the share id)
# + return - The wait, in seconds
isolated function paceDelaySeconds(time:Utc? lastPublished, time:Utc now, int gapSeconds, int jitterSeconds,
        string seed) returns decimal {
    if lastPublished is () || gapSeconds <= 0 {
        return 0;
    }
    decimal remaining = <decimal>gapSeconds - time:utcDiffSeconds(now, lastPublished);
    if remaining <= 0d {
        return 0;
    }
    // Seeded with the last publish too, so each wait after a new post gets a new jitter.
    return remaining + <decimal>jitterOf(seed + time:utcToString(lastPublished), jitterSeconds);
}

# A number from 0 to `maxSeconds`, the same for the same seed (no shared random state; easy to test).
#
# + seed - Seed
# + maxSeconds - Largest value; 0 or less gives 0
# + return - The jitter, in seconds
isolated function jitterOf(string seed, int maxSeconds) returns int {
    if maxSeconds <= 0 {
        return 0;
    }
    int h = 7;
    foreach int c in seed.toCodePointInts() {
        h = (h * 31 + c) % 1000000007;
    }
    return h % (maxSeconds + 1);
}
