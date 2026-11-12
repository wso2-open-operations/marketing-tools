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

// Novera seen counts (V023) against PostgreSQL: the broadcast id round-trips with the sent announcement, the due
// list keeps to the window and the refresh interval (never counted first), a count is saved and read back by the
// dashboards, and a time-only save waits a refresh interval without touching the count.

import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.reporting;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

function sentWithNoveraId(announcements:PgAnnouncementWriter writer, string? notificationId, time:Utc now)
        returns string|error {
    string id = types:newUuidV7();
    announcements:Announcement q = check announcements:queueAnnouncement((), id, check int:fromHexString(uniq()), now);
    check writer.insertQueued(q);
    check writer.save(check announcements:markSent(check announcements:markAttempted(q, now), "novera:" + id, now,
            notificationId), []);
    return id;
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testNoveraSeenCountsDueSavedAndRead() returns error? {
    postgresql:Client db = check jobs();
    announcements:PgAnnouncementWriter writer = new (db);
    announcements:PgAnnouncementRepository reader = new (db);
    time:Utc now = time:utcNow();
    string neverCounted = check sentWithNoveraId(writer, "n-never-" + uniq(), now);
    string countedLongAgo = check sentWithNoveraId(writer, "n-old-" + uniq(), now);
    string countedJustNow = check sentWithNoveraId(writer, "n-now-" + uniq(), now);
    string outsideWindow = check sentWithNoveraId(writer, "n-window-" + uniq(), now);
    string noId = check sentWithNoveraId(writer, (), now);
    _ = check db->execute(`UPDATE announcement SET novera_checked_at = now() - interval '4 hours'
                           WHERE campaign_id = CAST(${countedLongAgo} AS uuid)`);
    _ = check db->execute(`UPDATE announcement SET novera_checked_at = now() - interval '10 minutes'
                           WHERE campaign_id = CAST(${countedJustNow} AS uuid)`);
    _ = check db->execute(`UPDATE announcement SET sent_at = now() - interval '20 days'
                           WHERE campaign_id = CAST(${outsideWindow} AS uuid)`);

    announcements:Announcement? stored = check reader.findByCampaign(neverCounted);
    test:assertTrue(stored is announcements:Announcement && (stored.noveraNotificationId ?: "").startsWith("n-never-"),
            "the broadcast id is saved with the sent announcement and read back");

    string[] mine = [neverCounted, countedLongAgo, countedJustNow, outsideWindow, noId];
    string[] due = from announcements:NoveraStatsTarget t in check announcements:noveraStatsDue(db, 14, 10800, 1000)
        where mine.indexOf(t.campaignId) !is ()
        select t.campaignId;
    test:assertEquals(due, [neverCounted, countedLongAgo], "never counted first; recent, inside the window, with an id");

    check announcements:saveNoveraStats(db, neverCounted, {recipients: 900, seen: 312}, now);
    check announcements:saveNoveraStats(db, countedLongAgo, (), now);
    map<reporting:Delivery> delivery = check reporting:deliveryOf(db, [neverCounted, countedLongAgo, noId]);
    reporting:Delivery? counted = delivery[neverCounted];
    test:assertTrue(counted is reporting:Delivery && counted.recipients == 900 && counted.seen == 312
            && counted.seenCheckedAt !is (), "the dashboards read the count and when it was taken");
    reporting:Delivery? timeOnly = delivery[countedLongAgo];
    test:assertTrue(timeOnly is reporting:Delivery && timeOnly.seen is () && timeOnly.seenCheckedAt !is (),
            "a time-only save keeps no count");
    reporting:Delivery? uncounted = delivery[noId];
    test:assertTrue(uncounted is reporting:Delivery && uncounted.status == "SENT" && uncounted.recipients is ());

    string[] dueAfter = from announcements:NoveraStatsTarget t in check announcements:noveraStatsDue(db, 14, 10800, 1000)
        where mine.indexOf(t.campaignId) !is ()
        select t.campaignId;
    test:assertEquals(dueAfter, [], "both wait a refresh interval after being asked");
    check db.close();
}
