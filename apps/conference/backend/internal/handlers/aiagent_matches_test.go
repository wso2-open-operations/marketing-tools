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
	"encoding/json"
	"net/http"
	"testing"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_Matches_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/users/me/matches", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_Matches_ClientError_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{matchesErr: errBoom}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/users/me/matches", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_Matches_HappyPath_OneEnrichedOneNotFound(t *testing.T) {
	client := &fakeAIAgentClient{matches: []models.RecommendedUser{
		{Email: "known@wso2.com", Name: "Known User", Company: "WSO2", Title: "Eng", Reason: "shared track", Tags: []string{"go"}},
		{Email: "unknown@wso2.com", Name: "Unknown User", Tags: []string{}},
	}}
	attendees := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		"known@wso2.com": {IDPUUID: "uuid-known", ProfileURL: "https://example.com/known.png"},
	}}
	user := &middleware.UserInfo{Email: testUser.Email, UserID: testUser.UserID, RawToken: "raw-jwt-value"}
	h := NewAIAgentHandler(client, attendees, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, user)

	w := doRequest(r, http.MethodGet, "/users/me/matches", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got []models.MatchedUser
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 matches, got %d: %+v", len(got), got)
	}
	if got[0].UUID != "uuid-known" || got[0].ProfileURL == nil || *got[0].ProfileURL != "https://example.com/known.png" {
		t.Errorf("known match not enriched correctly: %+v", got[0])
	}
	if got[1].UUID != "" || got[1].ProfileURL != nil {
		t.Errorf("unknown match should have empty uuid/absent profileUrl, got %+v", got[1])
	}
	if client.jwtSeen != "raw-jwt-value" {
		t.Errorf("jwtSeen = %q, want the user's RawToken forwarded verbatim", client.jwtSeen)
	}
}

func TestAIAgentHandler_Matches_RealDBErrorAbortsWholeRequest(t *testing.T) {
	client := &fakeAIAgentClient{matches: []models.RecommendedUser{
		{Email: "a@wso2.com", Name: "A"},
		{Email: "b@wso2.com", Name: "B"},
	}}
	attendees := &fakeAttendeeRepo{getErr: errBoom}
	h := NewAIAgentHandler(client, attendees, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/users/me/matches", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusInternalServerError, w.Body.String())
	}
}
