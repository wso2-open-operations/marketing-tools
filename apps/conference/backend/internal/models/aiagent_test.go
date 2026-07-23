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

func TestRecommendedUser_UnmarshalsExpectedTags(t *testing.T) {
	raw := `{"email":"a@wso2.com","name":"A","company":"WSO2","title":"Eng","reason":"shared track","tags":["go","ai"]}`
	var got RecommendedUser
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("Unmarshal error: %v", err)
	}
	if got.Email != "a@wso2.com" || got.Name != "A" || got.Company != "WSO2" || got.Title != "Eng" || got.Reason != "shared track" {
		t.Errorf("unexpected fields: %+v", got)
	}
	if len(got.Tags) != 2 || got.Tags[0] != "go" {
		t.Errorf("Tags = %v", got.Tags)
	}
}

func TestMatchedUser_MarshalsExpectedTags(t *testing.T) {
	profileURL := "https://example.com/p.png"
	m := MatchedUser{UUID: "u-1", Name: "A", Company: "WSO2", Title: "Eng", Reason: "r", Tags: []string{"go"}, ProfileURL: &profileURL}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("Marshal error: %v", err)
	}
	var got map[string]any
	json.Unmarshal(b, &got)
	for _, k := range []string{"uuid", "name", "company", "title", "reason", "tags", "profileUrl"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing key %q in %v", k, got)
		}
	}
}

func TestMatchedUser_OmitsProfileURLWhenNil(t *testing.T) {
	m := MatchedUser{UUID: "u-1", Name: "A", Tags: []string{}}
	b, _ := json.Marshal(m)
	var got map[string]any
	json.Unmarshal(b, &got)
	if _, ok := got["profileUrl"]; ok {
		t.Errorf("expected profileUrl omitted when nil, got %v", got)
	}
}

func TestO2BarRecommendationInput_MarshalsQuestionOmitEmpty(t *testing.T) {
	b, _ := json.Marshal(O2BarRecommendationInput{})
	var got map[string]any
	json.Unmarshal(b, &got)
	if _, ok := got["question"]; ok {
		t.Errorf("expected question omitted when nil, got %v", got)
	}

	q := "when is the next slot?"
	b, _ = json.Marshal(O2BarRecommendationInput{Question: &q})
	json.Unmarshal(b, &got)
	if got["question"] != q {
		t.Errorf("question = %v, want %q", got["question"], q)
	}
}

func TestO2BarRecommendationResponse_UnmarshalsExpectedTags(t *testing.T) {
	raw := `{"email":"a@wso2.com","name":"A","reason":"r","recommendedQuestions":["q1"],
	"availableTimeSlots":[{"startTime":"10:00","endTime":"10:30"}],"profileUrl":"https://x/p.png"}`
	var got O2BarRecommendationResponse
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("Unmarshal error: %v", err)
	}
	if got.Email != "a@wso2.com" || got.Reason != "r" {
		t.Errorf("unexpected fields: %+v", got)
	}
	if len(got.AvailableTimeSlots) != 1 || got.AvailableTimeSlots[0].StartTime != "10:00" {
		t.Errorf("AvailableTimeSlots = %+v", got.AvailableTimeSlots)
	}
	if got.ProfileURL == nil || *got.ProfileURL != "https://x/p.png" {
		t.Errorf("ProfileURL = %v", got.ProfileURL)
	}
}

func TestO2BarRecommendation_MarshalsExpectedTags(t *testing.T) {
	rec := O2BarRecommendation{
		UUID: "u-1", Name: "A", Email: "a@wso2.com", Reason: "r",
		RecommendedQuestions: []string{"q1"},
		AvailableTimeSlots:   []O2BarTimeSlot{{StartTime: "10:00", EndTime: "10:30"}},
	}
	b, _ := json.Marshal(rec)
	var got map[string]any
	json.Unmarshal(b, &got)
	for _, k := range []string{"uuid", "name", "email", "reason", "recommendedQuestions", "availableTimeSlots"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing key %q in %v", k, got)
		}
	}
	if _, ok := got["profileUrl"]; ok {
		t.Errorf("expected profileUrl omitted when nil, got %v", got)
	}
}

func TestPersonalizeAgentUserProfile_MarshalsExpectedTags(t *testing.T) {
	p := PersonalizeAgentUserProfile{
		Company: "WSO2", Country: "LK", Email: "a@wso2.com",
		LinkedInInfo: "info", Name: "A", Title: "Eng",
	}
	b, _ := json.Marshal(p)
	var got map[string]any
	json.Unmarshal(b, &got)
	for _, k := range []string{"company", "country", "email", "linkedInInfo", "name", "title"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing key %q in %v", k, got)
		}
	}
}

func TestPickedForYouSession_UnmarshalsExpectedTags(t *testing.T) {
	raw := `{
		"id":"s-1","title":"T","description":"D","category":"C",
		"startTime":"09:00","endTime":"10:00","isFeedbackNotified":false,
		"locationId":"loc-1","venueId":"venue-1","agendaId":5,
		"youtubeLink":null,"slidesLink":null,"pdfLink":null,
		"location":{"id":"loc-1","name":"Hall A","address":"addr","floorPlanUrl":"url"},
		"venue":{"id":1,"name":"Venue","geoCoordinates":"0,0"},
		"agenda":{"id":5,"eventId":2,"name":"Day 1","date":"2026-01-01"},
		"sessionSpeakers":[{"id":1,"speakerId":"sp-1","sessionId":10}],
		"sessionSponsors":[],
		"personalizedDescription":"desc"
	}`
	var got PickedForYouSession
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("Unmarshal error: %v", err)
	}
	if got.ID != "s-1" || got.AgendaID != 5 || got.Location.Name != "Hall A" || got.Venue.ID != 1 || got.Agenda.EventID != 2 {
		t.Errorf("unexpected fields: %+v", got)
	}
	if len(got.SessionSpeakers) != 1 || got.SessionSpeakers[0].SpeakerID != "sp-1" {
		t.Errorf("SessionSpeakers = %+v", got.SessionSpeakers)
	}
	if got.YoutubeLink != nil {
		t.Errorf("YoutubeLink = %v, want nil", got.YoutubeLink)
	}
}

func TestChatRequest_MarshalsExpectedTags(t *testing.T) {
	req := ChatRequest{
		History:  []ChatHistory{{Question: "q1", Answer: "a1"}},
		Question: "q2",
	}
	b, _ := json.Marshal(req)
	var got map[string]any
	json.Unmarshal(b, &got)
	if _, ok := got["history"]; !ok {
		t.Errorf("missing history key in %v", got)
	}
	if got["question"] != "q2" {
		t.Errorf("question = %v", got["question"])
	}
}

func TestChatResponse_UnmarshalsExpectedTags(t *testing.T) {
	raw := `{"response":"hello","suggestions":["s1","s2"]}`
	var got ChatResponse
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("Unmarshal error: %v", err)
	}
	if got.Response != "hello" || len(got.Suggestions) != 2 {
		t.Errorf("unexpected fields: %+v", got)
	}
}

func TestAIFeatureStatus_MarshalsExpectedTags(t *testing.T) {
	s := AIFeatureStatus{EnabledChatAssistant: true, EnabledPersonalizedAgenda: false, EnabledMatchMaker: true, EnabledO2Bar: false}
	b, _ := json.Marshal(s)
	var got map[string]any
	json.Unmarshal(b, &got)
	for _, k := range []string{"enabledChatAssistant", "enabledPersonalizedAgenda", "enabledMatchMaker", "enabledO2Bar"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing key %q in %v", k, got)
		}
	}
}
