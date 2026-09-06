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
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"
	"golang.org/x/oauth2"

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

// lockedBuffer is a bytes.Buffer whose writes are serialized. A slog handler
// may be invoked from any goroutine, and captureAILogs installs one as the
// process-wide default, so a bare bytes.Buffer behind it is an unsynchronized
// writer shared across whatever is running -- which `go test -race` reports as
// a hard failure, not a flake.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// String returns everything written so far, under the same lock as Write so a
// reader never observes a torn record.
func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// captureAILogs redirects slog to a buffer for the duration of the test and
// returns it, so assertions can be made about what an operator actually sees.
//
// It swaps slog.Default(), which is process-wide state. A test that calls this
// must NOT call t.Parallel(), and neither may any other test in package
// handlers: two parallel tests would each install their own handler, and each
// would then see the other's records or none of its own, so the assertions
// below would pass or fail on scheduling. The returned buffer is mutex-guarded
// so that mistake degrades to a wrong assertion instead of a `-race` failure --
// the guard is a seatbelt, not a licence to parallelize.
func captureAILogs(t *testing.T) *lockedBuffer {
	t.Helper()
	buf := &lockedBuffer{}
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return buf
}

// logMessages returns the "msg" field of every JSON log record in buf. The
// deployed log viewer shows this field and drops the attributes beside it,
// which is why the tests below assert on it specifically.
func logMessages(t *testing.T, buf *lockedBuffer) []string {
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

// tokenFetchError reproduces, layer for layer, the error a rejected OAuth2
// token fetch actually reaches a handler as. The oauth2 transport gives up
// before the AI request is ever sent, so http.Client.Do surfaces it as a
// *url.Error wrapping *oauth2.RetrieveError, and clients/aiagent wraps that
// twice more on the way out. Both aiServiceUnreachable and
// respondAIUpstreamError classify it by unwrapping to the RetrieveError, so a
// hand-built error that flattens a layer would prove nothing about the real
// path.
func tokenFetchError(status int) error {
	const target = "https://ai.example.com/assistant/chat"
	retrieveErr := &oauth2.RetrieveError{
		Response: &http.Response{StatusCode: status},
		Body:     []byte(`{"error":"invalid_client"}`),
	}
	return fmt.Errorf("aiagent: retrieving chat response: %w",
		fmt.Errorf("request to %s failed: %w", target,
			&url.Error{Op: "Post", URL: target, Err: retrieveErr}))
}

// A token endpoint that *rejects* the credentials is a deployment fault that
// will never clear on its own, so it must not be dressed up as a retriable
// outage. The failure travels as a *url.Error like any unreachable service, so
// without the token-failure branch in aiServiceUnreachable it degrades to a
// 503 and an operator watches a "temporarily unavailable" that is permanent.
func TestAIAgentHandler_TokenRejected_Returns500WithCredentialHint(t *testing.T) {
	logs := captureAILogs(t)
	client := &fakeAIAgentClient{chatErr: tokenFetchError(http.StatusUnauthorized)}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusInternalServerError, w.Body.String())
	}
	joined := strings.Join(logMessages(t, logs), "\n")
	// In the message, not an attribute: the deployed log viewer renders only
	// slog's msg, so a status left in an attribute is invisible where people
	// look. Without this the entry reads as a bare "retrieving chat response
	// failed" and says nothing about which hop refused.
	if !strings.Contains(joined, "OAuth2 token request") || !strings.Contains(joined, "401") {
		t.Errorf("log message %q should name the token request and the status it got", joined)
	}
	// It also has to name the right thing to fix. The attendee's JWT is not
	// involved -- the token fetch never carried it -- so the hint sends the
	// operator to this service's own gateway credentials.
	if !strings.Contains(joined, "AI_CLIENT_SECRET") {
		t.Errorf("log message %q should point at this service's AI gateway credentials", joined)
	}
}

// 429 from the token endpoint is Asgardeo throttling, not a bad secret: it
// clears in seconds. Treating every token failure as permanent -- the original
// bug -- turned a few throttled seconds into a hard 500 the frontend would not
// retry, and sent whoever investigated to re-check credentials that were fine.
func TestAIAgentHandler_TokenThrottled_Returns503WithoutCredentialHint(t *testing.T) {
	logs := captureAILogs(t)
	client := &fakeAIAgentClient{chatErr: tokenFetchError(http.StatusTooManyRequests)}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d (a throttled token endpoint is retriable), body: %s",
			w.Code, http.StatusServiceUnavailable, w.Body.String())
	}
	joined := strings.Join(logMessages(t, logs), "\n")
	if !strings.Contains(joined, "OAuth2 token request") || !strings.Contains(joined, "429") {
		t.Errorf("log message %q should still name the token request and the status it got", joined)
	}
	if strings.Contains(joined, "credentials") || strings.Contains(joined, "AI_CLIENT_SECRET") {
		t.Errorf("log message %q sends the operator after credentials over a self-clearing throttle", joined)
	}
}

// A token endpoint having an incident is the other retriable half: 5xx is not
// a statement about the credentials either, so it degrades to 503 like 429.
func TestAIAgentHandler_TokenEndpointDown_Returns503(t *testing.T) {
	captureAILogs(t)
	client := &fakeAIAgentClient{chatErr: tokenFetchError(http.StatusBadGateway)}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusServiceUnavailable, w.Body.String())
	}
}

// The gateway answers 403/`900908` when this service's OAuth2 application is
// not subscribed to con-ai's API. That is a different misconfiguration from a
// bad secret but has the same fix location, so it earns the same hint. Only
// the 401 case was ever covered, so narrowing the hint to 401 stayed green.
func TestAIAgentHandler_UpstreamForbidden_NamesCauseInLogMessage(t *testing.T) {
	logs := captureAILogs(t)
	err := &aiagent.StatusError{
		StatusCode: http.StatusForbidden,
		URL:        "https://ai.example.com/assistant/chat",
		Body:       `{"error_message":"Resource forbidden","code":"900908"}`,
	}
	h := NewAIAgentHandler(&fakeAIAgentClient{chatErr: err}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
	joined := strings.Join(logMessages(t, logs), "\n")
	if !strings.Contains(joined, "403") {
		t.Errorf("log message %q should name the upstream status", joined)
	}
	if !strings.Contains(joined, "AI_CLIENT_ID") {
		t.Errorf("log message %q should point at this service's gateway credentials", joined)
	}
	if body := w.Body.String(); strings.Contains(body, "900908") {
		t.Errorf("response body %q leaks the gateway's error taxonomy to the attendee", body)
	}
}
