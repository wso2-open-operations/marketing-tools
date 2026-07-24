// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

package models

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestSession_JSONShape(t *testing.T) {
	start := time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	end := time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)
	slotIndex := 12
	s := Session{
		ID:            "session-1",
		Kind:          "session",
		Title:         "Intro to WSO2",
		Description:   "A talk.",
		Category:      "integration",
		StartTime:     &start,
		EndTime:       &end,
		DayID:         "day-1",
		TrackID:       "track-1",
		SlotIndex:     &slotIndex,
		DurationSlots: 6,
		RoomID:        "room-1",
		ArticleURL:    "https://example.com/article",
		ArticleLabel:  "Slides",
		VideoURL:      "https://example.com/video",
		VideoLabel:    "Recording",
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{
		"id", "kind", "title", "description", "category", "startTime", "endTime",
		"dayId", "trackId", "slotIndex", "durationSlots", "roomId",
		"articleUrl", "articleLabel", "videoUrl", "videoLabel",
	} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	for _, key := range []string{"agendaId", "venueId", "locationId", "isFeedbackNotified", "youtubeLink", "slidesLink", "pdfLink"} {
		if _, ok := got[key]; ok {
			t.Errorf("expected no %q key (dropped, no equivalent in new schema), got %v", key, got)
		}
	}
}

func TestSession_OptionalFieldsOmittedWhenEmpty(t *testing.T) {
	s := Session{ID: "session-1", Kind: "break", Title: "Coffee Break", DurationSlots: 1}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{
		"description", "category", "startTime", "endTime", "dayId", "trackId", "slotIndex",
		"roomId", "articleUrl", "articleLabel", "videoUrl", "videoLabel",
	} {
		if _, ok := got[key]; ok {
			t.Errorf("expected %q to be omitted when empty/unscheduled, got %v", key, got)
		}
	}
	if _, ok := got["durationSlots"]; !ok {
		t.Errorf("expected durationSlots to always be present, got %v", got)
	}
}

// A session time expressed in a non-UTC venue zone must serialize with that
// zone's real offset, not a fake Z. This is the contract the frontend's
// parseConferenceTime timezone-patching hack (FE.md 3.4) exists to work
// around; once the offset is present the client can Date-parse directly.
func TestSession_StartTimeSerializesWithZoneOffset(t *testing.T) {
	colombo, err := time.LoadLocation("Asia/Colombo") // fixed +05:30, no DST
	if err != nil {
		t.Skipf("tzdata for Asia/Colombo unavailable: %v", err)
	}
	start := time.Date(2026, 7, 1, 9, 0, 0, 0, colombo)
	s := Session{ID: "s1", Kind: "session", Title: "T", DurationSlots: 6, StartTime: &start}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	startStr, _ := got["startTime"].(string)
	if !strings.HasSuffix(startStr, "+05:30") {
		t.Errorf("startTime = %q, want a +05:30 offset, not a fake Z", startStr)
	}
	if strings.HasSuffix(startStr, "Z") {
		t.Errorf("startTime = %q ends in Z; the naive-UTC bug is still present", startStr)
	}
}

// A session embeds its speakers so the client needs no session<->speaker join
// (FE.md 3.2). The embedded shape is {id, name, photoUrl, isModerator} with
// string ids.
func TestSession_EmbedsSpeakers(t *testing.T) {
	s := Session{
		ID: "s1", Kind: "session", Title: "T", DurationSlots: 6,
		Speakers: []SessionSpeaker{{ID: "sp1", Name: "Ada Lovelace", PhotoURL: "https://x/a.webp", IsModerator: true}},
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got struct {
		Speakers []map[string]any `json:"speakers"`
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	if len(got.Speakers) != 1 {
		t.Fatalf("speakers = %v, want a single element", got.Speakers)
	}
	for _, key := range []string{"id", "name", "photoUrl", "isModerator"} {
		if _, ok := got.Speakers[0][key]; !ok {
			t.Errorf("embedded speaker missing key %q, got %v", key, got.Speakers[0])
		}
	}
	if id, ok := got.Speakers[0]["id"].(string); !ok || id != "sp1" {
		t.Errorf("speaker id = %v, want string \"sp1\"", got.Speakers[0]["id"])
	}
}

// The empty-string-as-absent sentinel (FE.md 3.6) must not reappear: an empty
// category serializes to an omitted key, never "".
func TestSession_EmptyCategoryIsOmittedNotEmptyString(t *testing.T) {
	s := Session{ID: "s1", Kind: "session", Title: "T", DurationSlots: 1, Category: ""}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	if strings.Contains(string(b), `"category"`) {
		t.Errorf("category key present for an empty category; want it omitted: %s", b)
	}
}
