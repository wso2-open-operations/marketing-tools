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
)

func TestSpeaker_JSONShape(t *testing.T) {
	s := Speaker{
		ID:          "speaker-1",
		Name:        "Jay Howell",
		Description: "Principal Engineer",
		Bio:         "Works on integration.",
		PhotoURL:    "https://example.com/jay.webp",
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"id", "name", "description", "bio", "photoUrl"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	if _, ok := got["email"]; ok {
		t.Errorf("expected no email key in the new schema's Speaker response, got %v", got)
	}
}

func TestSpeaker_DescriptionOmittedWhenEmpty(t *testing.T) {
	s := Speaker{ID: "speaker-1", Name: "No Title"}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	if _, ok := got["description"]; ok {
		t.Errorf("expected description to be omitted when empty, got %v", got)
	}
}

func TestSpeakerSummary_JSONShape(t *testing.T) {
	s := SpeakerSummary{
		ID:       "speaker-1",
		Name:     "Jay Howell",
		Bio:      "Works on integration.",
		PhotoURL: "https://example.com/jay.webp",
		SessionSpeakers: []SessionSpeakerWithEvent{
			{SpeakerID: "speaker-1", SessionID: "session-1", EventID: "config-1"},
		},
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	sessionSpeakers, ok := got["sessionSpeakers"].([]any)
	if !ok || len(sessionSpeakers) != 1 {
		t.Fatalf("expected one sessionSpeakers entry, got %v", got["sessionSpeakers"])
	}
	entry, ok := sessionSpeakers[0].(map[string]any)
	if !ok {
		t.Fatalf("expected sessionSpeakers[0] to be an object, got %T", sessionSpeakers[0])
	}
	for _, key := range []string{"speakerId", "sessionId", "eventId"} {
		if _, ok := entry[key]; !ok {
			t.Errorf("expected JSON key %q in sessionSpeakers entry, got %v", key, entry)
		}
	}
	if _, ok := entry["id"]; ok {
		t.Errorf("expected no surrogate id key (new schema has no equivalent), got %v", entry)
	}
}

func TestSpeakerSummary_SessionSpeakersAlwaysPresentEvenWhenEmpty(t *testing.T) {
	s := SpeakerSummary{ID: "speaker-1", Name: "No Sessions Yet"}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	if _, ok := got["sessionSpeakers"]; !ok {
		t.Errorf("expected sessionSpeakers key to always be present (matches Ballerina's non-optional field), got %v", got)
	}
}
