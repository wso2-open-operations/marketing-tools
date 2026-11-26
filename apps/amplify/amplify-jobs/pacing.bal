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

// Pacing of LinkedIn posts, so LinkedIn never sees the app post in bursts that look automated.
// - Per employee: sharing every open campaign at once, by hand or by a script, queues them all; the Run then posts
//   one, and each next one only after `publishGapSeconds` plus a little jitter. Points come with each post, so
//   nobody's points grow faster than anyone else's.
// - Per campaign: the shares that arrive right after an announcement are spread over `spreadSeconds`.
// - For the app: a per-run, per-day and rolling-hour ceiling on posts (`postBudget`).

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

# Seconds a share must still wait for its point in the campaign's spread window: `opensAt` plus an offset of up
# to `spreadSeconds` picked from the share's id, so retries and deferrals keep the same point. 0 once the point
# has passed (a share requested late goes at once), with no open time, or with the spread off.
#
# + opensAt - When the campaign opened, `()` if unknown
# + now - Current time
# + spreadSeconds - Length of the window; 0 or less turns the spread off
# + seed - Picks the point (the share id)
# + return - The wait, in seconds
isolated function spreadDelaySeconds(time:Utc? opensAt, time:Utc now, int spreadSeconds, string seed) returns decimal {
    if opensAt is () || spreadSeconds <= 0 {
        return 0;
    }
    time:Utc point = time:utcAddSeconds(opensAt, <decimal>jitterOf("spread:" + seed, spreadSeconds));
    decimal remaining = time:utcDiffSeconds(point, now);
    return remaining > 0d ? remaining : 0;
}

# The run config with the admin's posting settings applied (S019). Settings win, inside the configurables: the daily
# cap is the smaller of the two; the hourly cap too when the configurable sets one (a setting of 0 can't lift a
# configured cap, and with the configurable at 0 the setting alone applies). The spread and the per-employee gap are
# taken from the settings as they are (they only slow posting down). An unset setting leaves the configurable.
#
# + cfg - Run config from the configurables
# + settings - This run's settings
# + return - The run config to post with
isolated function postingConfig(RunConfig cfg, RunSettings settings) returns RunConfig {
    RunConfig out = {...cfg};
    int? day = settings.maxPostsPerDay;
    if day is int {
        out.linkedinMaxPostsPerDay = day < cfg.linkedinMaxPostsPerDay ? day : cfg.linkedinMaxPostsPerDay;
    }
    int? hour = settings.maxPostsPerHour;
    if hour is int {
        if cfg.linkedinMaxPostsPerHour <= 0 {
            out.linkedinMaxPostsPerHour = hour;
        } else if hour > 0 && hour < cfg.linkedinMaxPostsPerHour {
            out.linkedinMaxPostsPerHour = hour;
        }
    }
    int? spread = settings.spreadMinutes;
    if spread is int {
        out.spreadSeconds = spread * 60;
    }
    int? gap = settings.publishGapMinutes;
    if gap is int {
        out.publishGapSeconds = gap * 60;
    }
    return out;
}

# LinkedIn posts a run may make: the per-run ceiling, cut to what is left of the day's and the rolling hour's.
#
# + cfg - Run config (`linkedinMaxPostsPerRun`, `...PerDay`, `...PerHour`; an hourly cap of 0 is off)
# + publishedToday - Posts published since 00:00 UTC
# + publishedLastHour - Posts published in the last hour
# + return - The budget, never negative
isolated function postBudget(RunConfig cfg, int publishedToday, int publishedLastHour) returns int {
    int budget = cfg.linkedinMaxPostsPerRun;
    int dailyLeft = cfg.linkedinMaxPostsPerDay - publishedToday;
    if dailyLeft < budget {
        budget = dailyLeft;
    }
    if cfg.linkedinMaxPostsPerHour > 0 {
        int hourlyLeft = cfg.linkedinMaxPostsPerHour - publishedLastHour;
        if hourlyLeft < budget {
            budget = hourlyLeft;
        }
    }
    return budget < 0 ? 0 : budget;
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
