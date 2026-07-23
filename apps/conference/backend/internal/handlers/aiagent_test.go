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
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// fakeAIAgentClient is shared across every AIAgentHandler test file in this
// package (Goals 2-7 of .claude/PLAN.md).
type fakeAIAgentClient struct {
	matches       []models.RecommendedUser
	matchesErr    error
	o2bar         []models.O2BarRecommendationResponse
	o2barErr      error
	o2barQuestion *string

	profileResp *http.Response
	profileErr  error

	agenda    []models.PickedForYouSession
	agendaErr error

	chatResp    *models.ChatResponse
	chatErr     error
	chatReqSeen models.ChatRequest

	jwtSeen string
}

func (f *fakeAIAgentClient) RetrieveMatches(ctx context.Context, jwtAssertion string) ([]models.RecommendedUser, error) {
	f.jwtSeen = jwtAssertion
	return f.matches, f.matchesErr
}

func (f *fakeAIAgentClient) RetrieveO2BarRecommendations(ctx context.Context, jwtAssertion string, question *string) ([]models.O2BarRecommendationResponse, error) {
	f.jwtSeen = jwtAssertion
	f.o2barQuestion = question
	return f.o2bar, f.o2barErr
}

func (f *fakeAIAgentClient) SendProfileInfo(ctx context.Context, jwtAssertion string, profile models.PersonalizeAgentUserProfile) (*http.Response, error) {
	f.jwtSeen = jwtAssertion
	return f.profileResp, f.profileErr
}

func (f *fakeAIAgentClient) RetrieveAgendaRecommendations(ctx context.Context, jwtAssertion string) ([]models.PickedForYouSession, error) {
	f.jwtSeen = jwtAssertion
	return f.agenda, f.agendaErr
}

func (f *fakeAIAgentClient) RetrieveChatResponse(ctx context.Context, jwtAssertion string, req models.ChatRequest) (*models.ChatResponse, error) {
	f.jwtSeen = jwtAssertion
	f.chatReqSeen = req
	return f.chatResp, f.chatErr
}

func newAIAgentTestRouter(h *AIAgentHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.GET("/ai-maintenance-status", h.MaintenanceStatus)
	r.GET("/users/me/matches", h.Matches)
	r.GET("/o2bar/recommendations", h.O2BarRecommendationsGet)
	r.POST("/o2bar/recommendations", h.O2BarRecommendationsPost)
	r.POST("/users/profile", h.PersonalizedProfile)
	r.GET("/agenda/recommendations", h.AgendaRecommendations)
	r.POST("/assistant/chat", h.Chat)
	return r
}

func TestAIAgentHandler_MaintenanceStatus_EchoesConfiguredFlags(t *testing.T) {
	status := config.AIFeatureStatus{
		EnabledChatAssistant:      true,
		EnabledPersonalizedAgenda: false,
		EnabledMatchMaker:         true,
		EnabledO2Bar:              false,
	}
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, status)
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/ai-maintenance-status", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	var got models.AIFeatureStatus
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got.EnabledChatAssistant != true || got.EnabledPersonalizedAgenda != false ||
		got.EnabledMatchMaker != true || got.EnabledO2Bar != false {
		t.Errorf("unexpected response: %+v", got)
	}
}

func TestAIAgentHandler_MaintenanceStatus_NoAuthRequired(t *testing.T) {
	// This route has no context param at all in the old code -- unlike
	// every other AI route, it works with no authenticated user in context.
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	req := httptest.NewRequest(http.MethodGet, "/ai-maintenance-status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
}
