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

func TestEvent_JSONShape(t *testing.T) {
	e := Event{ID: "event-1", Name: "WSO2Con NA", IsCurrent: true}

	b, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"id", "name", "isCurrent"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	if _, ok := got["location"]; ok {
		t.Errorf("expected no %q key (dropped, no equivalent in new schema), got %v", "location", got)
	}
}

func TestEventAgenda_JSONShape(t *testing.T) {
	a := EventAgenda{
		ID:      "day-1",
		EventID: "event-1",
		Name:    "Day 1",
		Date:    "2026-05-20",
		Sessions: []Session{
			{ID: "session-1", Kind: "session", Title: "Intro to WSO2", DurationSlots: 6},
		},
	}

	b, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"id", "eventId", "name", "date", "sessions"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	sessions, ok := got["sessions"].([]any)
	if !ok || len(sessions) != 1 {
		t.Errorf("sessions = %v, want a single-element array", got["sessions"])
	}
}

func TestEventAgenda_NameOmittedWhenEmpty(t *testing.T) {
	a := EventAgenda{ID: "day-1", EventID: "event-1", Date: "2026-05-20", Sessions: []Session{}}

	b, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	if _, ok := got["name"]; ok {
		t.Errorf("expected %q to be omitted when empty, got %v", "name", got)
	}
	sessions, ok := got["sessions"].([]any)
	if !ok || len(sessions) != 0 {
		t.Errorf("sessions = %v, want an empty array, not omitted", got["sessions"])
	}
}
