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

func TestFeedbackType_IsValid(t *testing.T) {
	tests := []struct {
		name string
		typ  FeedbackType
		want bool
	}{
		{"session", FeedbackSession, true},
		{"event", FeedbackEvent, true},
		{"empty", FeedbackType(""), false},
		{"unknown", FeedbackType("BOGUS"), false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.typ.IsValid(); got != tt.want {
				t.Errorf("IsValid() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFeedbackRequest_JSONShape(t *testing.T) {
	sessionID := "session-1"
	comment := "great talk"
	req := FeedbackRequest{
		SessionID:    &sessionID,
		Rating:       5,
		Comment:      &comment,
		FeedbackType: FeedbackSession,
	}

	b, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	if got["sessionId"] != sessionID {
		t.Errorf("sessionId = %v, want %v", got["sessionId"], sessionID)
	}
	if got["comment"] != comment {
		t.Errorf("comment = %v, want %v", got["comment"], comment)
	}
	if got["feedbackType"] != string(FeedbackSession) {
		t.Errorf("feedbackType = %v, want %v", got["feedbackType"], FeedbackSession)
	}
	if got["rating"] != float64(5) {
		t.Errorf("rating = %v, want 5", got["rating"])
	}
}

func TestFeedbackRequest_OptionalFieldsOmittedWhenNil(t *testing.T) {
	req := FeedbackRequest{Rating: 3, FeedbackType: FeedbackEvent}

	b, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"sessionId", "comment"} {
		if _, ok := got[key]; ok {
			t.Errorf("expected %q to be omitted when nil, got %v", key, got)
		}
	}
}
