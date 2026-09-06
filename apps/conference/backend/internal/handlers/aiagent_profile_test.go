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
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_PersonalizedProfile_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_PersonalizedProfile_PassesThroughRawResponse(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
	}{
		{"success", http.StatusOK, `{"status":"accepted"}`},
		{"client 4xx from external service passes through untouched", http.StatusBadRequest, `{"error":"bad profile"}`},
		{"server 5xx from external service passes through untouched", http.StatusInternalServerError, `{"error":"upstream down"}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := &fakeAIAgentClient{profileResp: &http.Response{
				StatusCode: tt.statusCode,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(tt.body)),
			}}
			h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
			r := newAIAgentTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{Email: "a@wso2.com"})
			if w.Code != tt.statusCode {
				t.Fatalf("status = %d, want %d", w.Code, tt.statusCode)
			}
			if w.Body.String() != tt.body {
				t.Errorf("body = %q, want byte-for-byte passthrough %q", w.Body.String(), tt.body)
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
		})
	}
}

func TestAIAgentHandler_PersonalizedProfile_ClientCallFailure_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{profileErr: errBoom}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_PersonalizedProfile_MalformedBody_Returns400(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/users/profile", strings.NewReader("{not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

// --- 2026-09-04 audit: D2 (POST /users/profile took its target from the body) ---

func TestAIAgentHandler_PersonalizedProfile_ForcesCallerEmail(t *testing.T) {
	// D2: the body's `email` selected whose AI profile got overwritten, and
	// con-ai no longer authenticates, so this handler is the only gate.
	client := &fakeAIAgentClient{profileResp: &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(`{"status":"accepted"}`)),
	}}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{
		Email: "victim@example.com", Name: "Victim",
	})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if client.profileSeen.Email != testUser.Email {
		t.Errorf("forwarded profile Email = %q, want %q (the JWT email, never the body's)", client.profileSeen.Email, testUser.Email)
	}
}

func TestAIAgentHandler_PersonalizedProfile_FeatureDisabled_Returns503(t *testing.T) {
	// Shares EnabledPersonalizedAgenda with GET /agenda/recommendations.
	client := &fakeAIAgentClient{profileErr: errBoom}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{EnabledPersonalizedAgenda: false}, nil)
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{Name: "X"})
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusServiceUnavailable, w.Body.String())
	}
	if client.jwtSeen != "" {
		t.Errorf("external client was called while feature disabled (jwtSeen=%q)", client.jwtSeen)
	}
}

// --- 2026-09-06: the gateway's 401 stopped being relayed to the attendee ---

// profileResponse builds the *http.Response the client hands back. withRequest
// decides whether Response.Request is populated: http.Client always fills it
// in, a response assembled by hand never does, and requestURLOf is reached only
// on the gateway-rejection path -- so both shapes have to run or a nil
// dereference there ships untested.
func profileResponse(status int, contentType, body string, withRequest bool) *http.Response {
	resp := &http.Response{
		StatusCode: status,
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
	if withRequest {
		u, _ := url.Parse("https://ai.example.com/profile/create")
		resp.Request = &http.Request{Method: http.MethodPost, URL: u}
	}
	return resp
}

// This route relays the upstream response verbatim, and for a gateway 401 that
// meant handing the attendee `401 {"code":"900901"}`. A frontend auth
// interceptor reads a 401 on an ordinary call as an expired session, so a
// credential fault on *this* backend became a logout and re-auth loop on every
// attendee's phone. 401 and 403 are now intercepted -- con-ai authenticates
// nobody and its envelope is {"message":...}, so those two can only be the
// gateway -- and routed through respondAIUpstreamError like every other AI
// route, which is also the only way this path (err == nil) can emit the
// credential hint at all.
func TestAIAgentHandler_PersonalizedProfile_GatewayRejection_Returns500(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		body        string
		withRequest bool
	}{
		{"401 on a double with no Request, as the old tests built them", http.StatusUnauthorized, `{"error_message":"Invalid Credentials","code":"900901"}`, false},
		{"401 with the Request http.Client fills in", http.StatusUnauthorized, `{"error_message":"Invalid Credentials","code":"900901"}`, true},
		{"403 -- this service's OAuth2 app is not subscribed to con-ai's API", http.StatusForbidden, `{"error_message":"Resource forbidden","code":"900908"}`, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			logs := captureAILogs(t)
			client := &fakeAIAgentClient{profileResp: profileResponse(tt.status, "application/json", tt.body, tt.withRequest)}
			h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
			r := newAIAgentTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{Name: "A"})

			if w.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want %d -- a gateway rejection must not reach the attendee as a 4xx, body: %s",
					w.Code, http.StatusInternalServerError, w.Body.String())
			}
			body := w.Body.String()
			if strings.Contains(body, "900901") || strings.Contains(body, "900908") || strings.Contains(body, "Invalid Credentials") {
				t.Errorf("response body %q relays the gateway's own error taxonomy to the attendee", body)
			}
			joined := strings.Join(logMessages(t, logs), "\n")
			if !strings.Contains(joined, strconv.Itoa(tt.status)) {
				t.Errorf("log message %q should name the upstream status", joined)
			}
			// The one fact worth acting on: nothing the attendee sent can
			// cause this, so the hint points at this service's own credentials.
			if !strings.Contains(joined, "AI_CLIENT_SECRET") {
				t.Errorf("log message %q should point at this service's AI gateway credentials", joined)
			}
		})
	}
}

// The load-bearing half of the interception above: it is deliberately narrow.
// con-ai's own failures are the reason this route relays verbatim at all -- a
// FastAPI 422 quotes the rejected field back, and the frontend shows it -- so
// widening the interception to "any 4xx", or to 4xx and 5xx, would replace
// every one of them with a generic 500 and leave the attendee no way to know
// what was wrong with their profile.
func TestAIAgentHandler_PersonalizedProfile_NonGatewayStatusesRelayedVerbatim(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		contentType string
		body        string
	}{
		{"422 from con-ai's own validation", http.StatusUnprocessableEntity, "application/json", `{"detail":[{"loc":["body","user","name"],"msg":"field required"}]}`},
		{"404 from the gateway is not a credential fault", http.StatusNotFound, "application/json", `{"error_message":"no matching resource","code":"900906"}`},
		{"2xx success", http.StatusOK, "application/json", `{"status":"accepted"}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// withRequest is true throughout: the verbatim path has to work on
			// the real client's response shape, not only on a bare double.
			client := &fakeAIAgentClient{profileResp: profileResponse(tt.status, tt.contentType, tt.body, true)}
			h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, allAIFeaturesOn, nil)
			r := newAIAgentTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{Name: "A"})

			if w.Code != tt.status {
				t.Fatalf("status = %d, want %d passed through untouched", w.Code, tt.status)
			}
			if w.Body.String() != tt.body {
				t.Errorf("body = %q, want byte-for-byte passthrough %q", w.Body.String(), tt.body)
			}
			if ct := w.Header().Get("Content-Type"); ct != tt.contentType {
				t.Errorf("Content-Type = %q, want %q", ct, tt.contentType)
			}
		})
	}
}
