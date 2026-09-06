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

package aiagent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestNewClient_SetsTimeout(t *testing.T) {
	c := NewClient(config.AIAgentConfig{
		ServiceURL:     "https://ai.example.com",
		RequestTimeout: 45 * time.Second,
	})
	if c.httpClient.Timeout != 45*time.Second {
		t.Errorf("httpClient.Timeout = %v, want 45s", c.httpClient.Timeout)
	}
}

func TestRetrieveMatches_Success(t *testing.T) {
	const jwt = "user-jwt-assertion"
	want := []models.RecommendedUser{{Email: "a@wso2.com", Name: "A", Tags: []string{"go"}}}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/networking/recommend" {
			t.Errorf("expected path /networking/recommend, got %q", r.URL.Path)
		}
		if got := r.Header.Get("x-jwt-assertion"); got != jwt {
			t.Errorf("x-jwt-assertion = %q, want %q", got, jwt)
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "{}" {
			t.Errorf("expected body {}, got %q", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	got, err := client.RetrieveMatches(context.Background(), jwt)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 || got[0].Email != "a@wso2.com" {
		t.Errorf("unexpected result: %+v", got)
	}
}

func TestRetrieveMatches_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	_, err := client.RetrieveMatches(context.Background(), "jwt")
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
}

func TestRetrieveO2BarRecommendations_NilQuestionSendsNoBody(t *testing.T) {
	want := []models.O2BarRecommendationResponse{{Email: "a@wso2.com", Name: "A"}}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/o2bar/recommend" {
			t.Errorf("expected path /o2bar/recommend, got %q", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		if len(body) != 0 {
			t.Errorf("expected no request body when question is nil, got %q", body)
		}
		if r.ContentLength > 0 {
			t.Errorf("expected zero content length, got %d", r.ContentLength)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	got, err := client.RetrieveO2BarRecommendations(context.Background(), "jwt", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 || got[0].Email != "a@wso2.com" {
		t.Errorf("unexpected result: %+v", got)
	}
}

func TestRetrieveO2BarRecommendations_WithQuestionSendsBody(t *testing.T) {
	question := "when is the next slot?"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var got map[string]string
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		if got["question"] != question {
			t.Errorf("question = %q, want %q", got["question"], question)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]models.O2BarRecommendationResponse{})
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	if _, err := client.RetrieveO2BarRecommendations(context.Background(), "jwt", &question); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSendProfileInfo_ReturnsRawResponse(t *testing.T) {
	const jwt = "user-jwt-assertion"
	profile := models.PersonalizeAgentUserProfile{Email: "a@wso2.com", Name: "A"}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/profile/create" {
			t.Errorf("expected path /profile/create, got %q", r.URL.Path)
		}
		if got := r.Header.Get("x-jwt-assertion"); got != jwt {
			t.Errorf("x-jwt-assertion = %q, want %q", got, jwt)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		if body["override"] != true {
			t.Errorf("override = %v, want true", body["override"])
		}
		user, ok := body["user"].(map[string]any)
		if !ok || user["email"] != "a@wso2.com" {
			t.Errorf("user = %v, want email a@wso2.com", body["user"])
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	resp, err := client.SendProfileInfo(context.Background(), jwt, profile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		t.Errorf("StatusCode = %d, want %d", resp.StatusCode, http.StatusCreated)
	}
	got, _ := io.ReadAll(resp.Body)
	if string(got) != `{"status":"accepted"}` {
		t.Errorf("body = %q, want raw passthrough", got)
	}
}

func TestSendProfileInfo_ClientCallFailureReturnsError(t *testing.T) {
	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: "http://127.0.0.1:1"}, &http.Client{Timeout: time.Second})

	_, err := client.SendProfileInfo(context.Background(), "jwt", models.PersonalizeAgentUserProfile{})
	if err == nil {
		t.Fatal("expected error when the external service is unreachable")
	}
}

func TestRetrieveAgendaRecommendations_Success(t *testing.T) {
	want := []models.PickedForYouSession{{ID: "s-1", Title: "T"}}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/agenda/create" {
			t.Errorf("expected path /agenda/create, got %q", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "{}" {
			t.Errorf("expected body {}, got %q", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	got, err := client.RetrieveAgendaRecommendations(context.Background(), "jwt")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 || got[0].ID != "s-1" {
		t.Errorf("unexpected result: %+v", got)
	}
}

func TestRetrieveChatResponse_Success(t *testing.T) {
	req := models.ChatRequest{
		History:  []models.ChatHistory{{Question: "q1", Answer: "a1"}},
		Question: "q2",
	}
	want := models.ChatResponse{Response: "hello", Suggestions: []string{"s1"}}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/assistant/chat" {
			t.Errorf("expected path /assistant/chat, got %q", r.URL.Path)
		}
		var got models.ChatRequest
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		if got.Question != req.Question || len(got.History) != 1 || got.History[0].Question != "q1" {
			t.Errorf("unexpected forwarded request: %+v", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(config.AIAgentConfig{ServiceURL: server.URL}, server.Client())

	got, err := client.RetrieveChatResponse(context.Background(), "jwt", req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Response != "hello" || len(got.Suggestions) != 1 {
		t.Errorf("unexpected result: %+v", got)
	}
}

// TestNewClient_SendsGatewayTokenAndAssertion pins the two-credential contract:
// the caller's JWT keeps travelling in x-jwt-assertion while an OAuth2
// client-credentials token is added in Authorization for the Choreo gateway
// fronting the AI service. Dropping either is a live outage -- without the
// token the gateway answers 401 {"code":"900901"} and every AI route surfaces a
// bare 500; without the assertion the AI service cannot tell who is asking.
func TestNewClient_SendsGatewayTokenAndAssertion(t *testing.T) {
	const jwt = "user-jwt-assertion"

	var gotGrantType, gotTokenAuth string
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("parsing token request form: %v", err)
		}
		gotGrantType = r.PostFormValue("grant_type")
		gotTokenAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"gateway-token","token_type":"Bearer","expires_in":3600}`)
	}))
	defer tokenSrv.Close()

	var gotAuth, gotAssertion string
	aiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotAssertion = r.Header.Get("x-jwt-assertion")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"response":"hi","suggestions":[]}`)
	}))
	defer aiSrv.Close()

	c := NewClient(config.AIAgentConfig{
		ServiceURL: aiSrv.URL,
		OAuth: config.OAuthClientConfig{
			TokenURL:     tokenSrv.URL,
			ClientID:     "ai-client",
			ClientSecret: "ai-secret",
		},
		RequestTimeout: 10 * time.Second,
	})

	if _, err := c.RetrieveChatResponse(context.Background(), jwt, models.ChatRequest{Question: "q"}); err != nil {
		t.Fatalf("RetrieveChatResponse: %v", err)
	}
	if gotAuth != "Bearer gateway-token" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer gateway-token")
	}
	if gotAssertion != jwt {
		t.Errorf("x-jwt-assertion = %q, want %q", gotAssertion, jwt)
	}
	if gotGrantType != "client_credentials" {
		t.Errorf("grant_type = %q, want client_credentials", gotGrantType)
	}
	// AuthStyleInHeader: credentials as HTTP Basic on the token request, which
	// is what Asgardeo expects and what the reference gateway sends by hand.
	wantBasic := "Basic " + base64.StdEncoding.EncodeToString([]byte("ai-client:ai-secret"))
	if gotTokenAuth != wantBasic {
		t.Errorf("token request Authorization = %q, want %q", gotTokenAuth, wantBasic)
	}
}

// TestNewClient_NoTokenWhenTokenURLEmpty covers an AI service reached directly
// with no gateway in front of it: no token is fetched and no Authorization
// header is sent, so an empty AI_TOKEN_URL stays a working local configuration.
func TestNewClient_NoTokenWhenTokenURLEmpty(t *testing.T) {
	var gotAuth string
	aiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"response":"hi","suggestions":[]}`)
	}))
	defer aiSrv.Close()

	c := NewClient(config.AIAgentConfig{ServiceURL: aiSrv.URL, RequestTimeout: 10 * time.Second})

	if _, err := c.RetrieveChatResponse(context.Background(), "jwt", models.ChatRequest{Question: "q"}); err != nil {
		t.Fatalf("RetrieveChatResponse: %v", err)
	}
	if gotAuth != "" {
		t.Errorf("Authorization = %q, want no header", gotAuth)
	}
}

// A non-2xx from the AI service (or a gateway in front of it) must carry its
// status out of this package, so handlers can name it in the log message
// instead of burying it in an attribute the deployed log viewer hides.
func TestStatusCodeFrom_CarriesUpstreamStatus(t *testing.T) {
	const gatewayBody = `{"error_message":"Invalid Credentials","code":"900901"}`
	aiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, gatewayBody)
	}))
	defer aiSrv.Close()

	c := NewClient(config.AIAgentConfig{ServiceURL: aiSrv.URL, RequestTimeout: 10 * time.Second})

	_, err := c.RetrieveChatResponse(context.Background(), "jwt", models.ChatRequest{Question: "q"})
	if err == nil {
		t.Fatal("expected an error for a 401 from the AI service")
	}
	status, ok := StatusCodeFrom(err)
	if !ok {
		t.Fatalf("StatusCodeFrom did not recognise %v as an upstream status failure", err)
	}
	if status != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", status, http.StatusUnauthorized)
	}
	if !strings.Contains(err.Error(), "900901") {
		t.Errorf("error = %q, want it to retain the upstream body", err.Error())
	}
	if _, isTokenFailure := TokenFetchStatusFrom(err); isTokenFailure {
		t.Error("a service 401 must not be reported as a token-fetch failure")
	}
}

// A rejected token request never reaches the AI service, so it must be
// distinguishable from that service being down -- bad credentials will not fix
// themselves, and reporting them as "temporarily unavailable" hides the cause.
func TestTokenFetchStatusFrom_DistinguishesRejectedCredentials(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_client"}`)
	}))
	defer tokenSrv.Close()

	aiCalled := false
	aiSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		aiCalled = true
	}))
	defer aiSrv.Close()

	c := NewClient(config.AIAgentConfig{
		ServiceURL: aiSrv.URL,
		OAuth: config.OAuthClientConfig{
			TokenURL:     tokenSrv.URL,
			ClientID:     "ai-client",
			ClientSecret: "wrong-secret",
		},
		RequestTimeout: 10 * time.Second,
	})

	_, err := c.RetrieveChatResponse(context.Background(), "jwt", models.ChatRequest{Question: "q"})
	if err == nil {
		t.Fatal("expected an error when the token endpoint rejects the credentials")
	}
	status, ok := TokenFetchStatusFrom(err)
	if !ok {
		t.Fatalf("TokenFetchStatusFrom did not recognise %v as a token-fetch failure", err)
	}
	if status != http.StatusUnauthorized {
		t.Errorf("token status = %d, want %d", status, http.StatusUnauthorized)
	}
	if _, isServiceStatus := StatusCodeFrom(err); isServiceStatus {
		t.Error("a token-fetch failure must not be reported as an AI service status")
	}
	if aiCalled {
		t.Error("the AI service must not be called when the token request fails")
	}
}
