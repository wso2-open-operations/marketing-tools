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

// Phase 4 sharing settings (S019): the native repost default in `GET /me`, and the posting limits amplify-jobs reads.

import ballerina/http;
import ballerina/test;

@test:Config {groups: ["settings"]}
function testPhase4SharingSettingsAreTypedAndChecked() {
    Settings defaults = settingsOf([]);
    test:assertEquals([defaults.maxPostsPerDay, defaults.maxPostsPerHour, defaults.spreadMinutes,
        defaults.publishGapMinutes], [450, 60, 120, 10]);
    test:assertFalse(defaults.nativeRepostDefault);
    Settings s = settingsOf([
        {key: SETTING_NATIVE_REPOST_DEFAULT, value: true, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: SETTING_MAX_POSTS_PER_DAY, value: 300, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: SETTING_MAX_POSTS_PER_HOUR, value: 0, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: SETTING_SPREAD_MINUTES, value: -1, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: SETTING_PUBLISH_GAP_MINUTES, value: "x", updatedBy: "a", updatedAt: [0, 0], version: 1}
    ]);
    test:assertTrue(s.nativeRepostDefault);
    test:assertEquals([s.maxPostsPerDay, s.maxPostsPerHour, s.spreadMinutes, s.publishGapMinutes], [300, 0, 120, 10],
            "0 turns the hourly cap off; a bad value keeps the default");

    test:assertEquals(checkSettingChange(SETTING_NATIVE_REPOST_DEFAULT, true), ());
    test:assertEquals(checkSettingChange(SETTING_NATIVE_REPOST_DEFAULT, "yes"),
            [INVALID_SETTING, "sharing.native_repost_default must be true or false"]);
    test:assertEquals(checkSettingChange(SETTING_MAX_POSTS_PER_DAY, 450), ());
    test:assertEquals(checkSettingChange(SETTING_MAX_POSTS_PER_DAY, 10001),
            [INVALID_SETTING, "sharing.max_posts_per_day must be a whole number from 0 to 10000"]);
    test:assertEquals(checkSettingChange(SETTING_MAX_POSTS_PER_HOUR, -1),
            [INVALID_SETTING, "sharing.max_posts_per_hour must be a whole number from 0 to 10000"]);
    test:assertEquals(checkSettingChange(SETTING_SPREAD_MINUTES, 1441),
            [INVALID_SETTING, "sharing.spread_minutes must be a whole number from 0 to 1440"]);
    test:assertEquals(checkSettingChange(SETTING_PUBLISH_GAP_MINUTES, 0), ());
    foreach string key in [SETTING_NATIVE_REPOST_DEFAULT, SETTING_MAX_POSTS_PER_DAY, SETTING_MAX_POSTS_PER_HOUR,
            SETTING_SPREAD_MINUTES, SETTING_PUBLISH_GAP_MINUTES] {
        test:assertTrue(isVisibleSetting(key), key);
        test:assertTrue(PO_SETTINGS.indexOf(key) is (), key + " is an admin setting");
        test:assertFalse(touchesSchedule([key]), key + " is read by amplify-jobs each run, not pushed");
    }
}

@test:Config {groups: ["settings"]}
function testMeCarriesTheNativeRepostDefault() returns error? {
    http:Response off = check send("GET", "/me", (), check employee("emp-native-default"));
    test:assertEquals(off.statusCode, 200);
    check assertShape(off, "Me");
    test:assertEquals(check (check off.getJsonPayload()).config.nativeRepostDefault, false);

    setSetting(SETTING_NATIVE_REPOST_DEFAULT, true);
    http:Response turnedOn = check send("GET", "/me", (), check employee("emp-native-default"));
    clearSettings();
    test:assertEquals(check (check turnedOn.getJsonPayload()).config.nativeRepostDefault, true, "every employee sees it");
}
