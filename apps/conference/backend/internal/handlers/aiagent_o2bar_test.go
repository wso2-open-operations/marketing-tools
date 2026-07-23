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

package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_O2BarRecommendationsGet_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/o2bar/recommendations", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_O2BarRecommendationsGet_ClientError_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{o2barErr: errBoom}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/o2bar/recommendations", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_O2BarRecommendationsGet_NoQuestionSent(t *testing.T) {
	client := &fakeAIAgentClient{o2bar: []models.O2BarRecommendationResponse{}}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/o2bar/recommendations", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if client.o2barQuestion != nil {
		t.Errorf("expected no question forwarded on GET, got %v", client.o2barQuestion)
	}
}

func TestAIAgentHandler_O2BarRecommendationsGet_ProfileURLPrefersAIResponse(t *testing.T) {
	client := &fakeAIAgentClient{o2bar: []models.O2BarRecommendationResponse{
		{
			Email: "known@wso2.com", Name: "Known", Reason: "r",
			RecommendedQuestions: []string{"q1"},
			AvailableTimeSlots:   []models.O2BarTimeSlot{{StartTime: "10:00", EndTime: "10:30"}},
			ProfileURL:           strPtr("https://ai.example.com/known.png"),
		},
		{
			Email: "fallback@wso2.com", Name: "Fallback", Reason: "r2",
			RecommendedQuestions: []string{"q2"},
			AvailableTimeSlots:   []models.O2BarTimeSlot{{StartTime: "11:00", EndTime: "11:30"}},
		},
		{
			Email: "unknown@wso2.com", Name: "Unknown", Reason: "r3",
		},
	}}
	attendees := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		"known@wso2.com":    {IDPUUID: "uuid-known", ProfileURL: "https://db.example.com/known.png"},
		"fallback@wso2.com": {IDPUUID: "uuid-fallback", ProfileURL: "https://db.example.com/fallback.png"},
	}}
	h := NewAIAgentHandler(client, attendees, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/o2bar/recommendations", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got []models.O2BarRecommendation
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 recommendations, got %d: %+v", len(got), got)
	}
	if got[0].ProfileURL == nil || *got[0].ProfileURL != "https://ai.example.com/known.png" {
		t.Errorf("expected AI's own profileUrl preferred, got %+v", got[0])
	}
	if got[0].UUID != "uuid-known" {
		t.Errorf("uuid = %q, want uuid-known", got[0].UUID)
	}
	if got[1].ProfileURL == nil || *got[1].ProfileURL != "https://db.example.com/fallback.png" {
		t.Errorf("expected DB fallback profileUrl when AI response has none, got %+v", got[1])
	}
	if got[2].UUID != "" || got[2].ProfileURL != nil {
		t.Errorf("expected empty uuid/absent profileUrl for unknown attendee, got %+v", got[2])
	}
}

func TestAIAgentHandler_O2BarRecommendationsGet_RealDBErrorAbortsWholeRequest(t *testing.T) {
	client := &fakeAIAgentClient{o2bar: []models.O2BarRecommendationResponse{{Email: "a@wso2.com"}}}
	attendees := &fakeAttendeeRepo{getErr: errBoom}
	h := NewAIAgentHandler(client, attendees, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/o2bar/recommendations", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusInternalServerError, w.Body.String())
	}
}

func TestAIAgentHandler_O2BarRecommendationsPost_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/o2bar/recommendations", models.O2BarRecommendationInput{})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_O2BarRecommendationsPost_ForwardsQuestionAndReturns201(t *testing.T) {
	client := &fakeAIAgentClient{o2bar: []models.O2BarRecommendationResponse{}}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	question := "when is the next slot?"
	w := doRequest(r, http.MethodPost, "/o2bar/recommendations", models.O2BarRecommendationInput{Question: &question})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if client.o2barQuestion == nil || *client.o2barQuestion != question {
		t.Errorf("question forwarded = %v, want %q", client.o2barQuestion, question)
	}
}

func TestAIAgentHandler_O2BarRecommendationsPost_MalformedBody_Returns400(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/o2bar/recommendations", bytes.NewBufferString("{not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func strPtr(s string) *string { return &s }
