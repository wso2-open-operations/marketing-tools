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
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/clients/aiagent"
	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// allAIFeaturesOn enables every AI feature flag. Handler tests that exercise a
// route's client/enrichment path (not its feature-gate) use it so the gate --
// which now short-circuits a disabled feature to 503 before any client call --
// lets them through. The disabled->503 behavior has its own dedicated tests.
var allAIFeaturesOn = config.AIFeatureStatus{
	EnabledChatAssistant:      true,
	EnabledPersonalizedAgenda: true,
	EnabledMatchMaker:         true,
	EnabledO2Bar:              true,
}

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
	profileSeen models.PersonalizeAgentUserProfile

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
	f.profileSeen = profile
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
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, status, nil)
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
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{}, nil)
	r := newAIAgentTestRouter(h, nil)

	req := httptest.NewRequest(http.MethodGet, "/ai-maintenance-status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
}

// captureAILogs redirects slog to a buffer for the duration of the test and
// returns it, so assertions can be made about what an operator actually sees.
func captureAILogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &buf
}

// logMessages returns the "msg" field of every JSON log record in buf. The
// deployed log viewer shows this field and drops the attributes beside it,
// which is why the tests below assert on it specifically.
func logMessages(t *testing.T, buf *bytes.Buffer) []string {
	t.Helper()
	var msgs []string
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var record struct {
			Msg string `json:"msg"`
		}
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatalf("log line is not JSON: %q: %v", line, err)
		}
		msgs = append(msgs, record.Msg)
	}
	return msgs
}

// A gateway 401 must name itself in the log *message*. It previously appeared
// only as "retrieving chat response failed", with the status hidden in an
// attribute the deployed log viewer does not render -- which is how an
// unauthenticated gateway call read as an unexplained server bug.
func TestAIAgentHandler_UpstreamUnauthorized_NamesCauseInLogMessage(t *testing.T) {
	logs := captureAILogs(t)
	err := &aiagent.StatusError{
		StatusCode: http.StatusUnauthorized,
		URL:        "https://ai.example.com/assistant/chat",
		Body:       `{"error_message":"Invalid Credentials","code":"900901"}`,
	}
	h := NewAIAgentHandler(&fakeAIAgentClient{chatErr: err}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
	msgs := logMessages(t, logs)
	if len(msgs) == 0 {
		t.Fatal("expected a log record")
	}
	joined := strings.Join(msgs, "\n")
	if !strings.Contains(joined, "401") {
		t.Errorf("log message %q should name the upstream status", joined)
	}
	if !strings.Contains(joined, "AI_CLIENT_ID") {
		t.Errorf("log message %q should point at this service's gateway credentials", joined)
	}
}

// The client-facing body stays generic: the upstream's own error text is for
// the logs, not for an attendee.
func TestAIAgentHandler_UpstreamUnauthorized_DoesNotLeakUpstreamBody(t *testing.T) {
	captureAILogs(t)
	err := &aiagent.StatusError{
		StatusCode: http.StatusUnauthorized,
		URL:        "https://ai.example.com/assistant/chat",
		Body:       `{"error_message":"Invalid Credentials","code":"900901"}`,
	}
	h := NewAIAgentHandler(&fakeAIAgentClient{chatErr: err}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if body := w.Body.String(); strings.Contains(body, "900901") || strings.Contains(body, "Invalid Credentials") {
		t.Errorf("response body %q leaks the upstream error", body)
	}
}

// A transport failure still degrades to a retriable 503 -- the AI service being
// briefly unreachable is not the same as this service being misconfigured.
func TestAIAgentHandler_UnreachableService_Returns503(t *testing.T) {
	captureAILogs(t)
	err := &url.Error{Op: "Post", URL: "https://ai.example.com/assistant/chat", Err: errBoom}
	h := NewAIAgentHandler(&fakeAIAgentClient{chatErr: err}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
}
