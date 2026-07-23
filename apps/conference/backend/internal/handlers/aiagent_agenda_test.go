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
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_AgendaRecommendations_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_AgendaRecommendations_ClientError_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{agendaErr: errBoom}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_AgendaRecommendations_ReturnsSessionsAsIs(t *testing.T) {
	want := []models.PickedForYouSession{{ID: "s-1", Title: "T", PersonalizedDescription: "d"}}
	h := NewAIAgentHandler(&fakeAIAgentClient{agenda: want}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	var got []models.PickedForYouSession
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 1 || got[0].ID != "s-1" || got[0].PersonalizedDescription != "d" {
		t.Errorf("unexpected result: %+v", got)
	}
}
