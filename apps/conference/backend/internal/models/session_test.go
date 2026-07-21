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
		"category", "startTime", "endTime", "dayId", "trackId", "slotIndex",
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

func TestSessionPresenters_JSONShape(t *testing.T) {
	sp := SessionPresenters{ID: "session-1", Name: "Intro to WSO2", Presenters: []string{"Jay Howell"}}

	b, err := json.Marshal(sp)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"id", "name", "presenters"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	presenters, ok := got["presenters"].([]any)
	if !ok || len(presenters) != 1 || presenters[0] != "Jay Howell" {
		t.Errorf("presenters = %v, want [\"Jay Howell\"]", got["presenters"])
	}
}
