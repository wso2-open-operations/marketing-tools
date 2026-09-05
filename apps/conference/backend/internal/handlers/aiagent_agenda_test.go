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
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_AgendaRecommendations_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_AgendaRecommendations_ClientError_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{agendaErr: errBoom}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

type fakeSessionDayReader struct {
	days map[string]string
	err  error
}

func (f *fakeSessionDayReader) DayIDsForSessions(ctx context.Context, ids []string) (map[string]string, error) {
	return f.days, f.err
}

func TestAIAgentHandler_AgendaRecommendations_DayAssociatesSessions(t *testing.T) {
	recs := []models.PickedForYouSession{{ID: "s-1", Title: "One"}, {ID: "s-2", Title: "Two"}}
	reader := &fakeSessionDayReader{days: map[string]string{"s-1": "day-A"}}
	h := NewAIAgentHandler(&fakeAIAgentClient{agenda: recs}, &fakeAttendeeRepo{}, allAIFeaturesOn, reader)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	var got []models.PickedForYouSession
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	byID := map[string]string{}
	for _, s := range got {
		byID[s.ID] = s.DayID
	}
	if byID["s-1"] != "day-A" {
		t.Errorf("s-1 dayId = %q, want day-A", byID["s-1"])
	}
	if byID["s-2"] != "" {
		t.Errorf("s-2 dayId = %q, want empty (id didn't resolve)", byID["s-2"])
	}
}

func TestAIAgentHandler_AgendaRecommendations_EnrichmentErrorStillReturns200(t *testing.T) {
	recs := []models.PickedForYouSession{{ID: "s-1"}}
	reader := &fakeSessionDayReader{err: errBoom}
	h := NewAIAgentHandler(&fakeAIAgentClient{agenda: recs}, &fakeAttendeeRepo{}, allAIFeaturesOn, reader)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (enrichment is best-effort)", w.Code)
	}
	var got []models.PickedForYouSession
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got) != 1 || got[0].DayID != "" {
		t.Errorf("expected the un-enriched recommendation to still be returned, got %+v", got)
	}
}

func TestAIAgentHandler_AgendaRecommendations_ReturnsSessionsAsIs(t *testing.T) {
	want := []models.PickedForYouSession{{ID: "s-1", Title: "T", PersonalizedDescription: "d"}}
	h := NewAIAgentHandler(&fakeAIAgentClient{agenda: want}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
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

func TestAIAgentHandler_AgendaRecommendations_FeatureDisabled_Returns503(t *testing.T) {
	client := &fakeAIAgentClient{agendaErr: errBoom}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{EnabledPersonalizedAgenda: false}, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/agenda/recommendations", nil)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusServiceUnavailable, w.Body.String())
	}
	if client.jwtSeen != "" {
		t.Errorf("external client was called while feature disabled (jwtSeen=%q)", client.jwtSeen)
	}
}
