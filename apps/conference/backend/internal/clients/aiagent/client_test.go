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
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestNewClient_SetsTimeout(t *testing.T) {
	c := NewClient(config.AIAgentConfig{
		MatchmakingServiceURL: "https://matchmaking.example.com",
		RequestTimeout:        45 * time.Second,
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

	client := NewClientWithHTTPClient(config.AIAgentConfig{MatchmakingServiceURL: server.URL}, server.Client())

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{MatchmakingServiceURL: server.URL}, server.Client())

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{MatchmakingServiceURL: server.URL}, server.Client())

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{MatchmakingServiceURL: server.URL}, server.Client())

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{PersonalizeAgentServiceURL: server.URL}, server.Client())

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
	client := NewClientWithHTTPClient(config.AIAgentConfig{PersonalizeAgentServiceURL: "http://127.0.0.1:1"}, &http.Client{Timeout: time.Second})

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{PickedForYouServiceURL: server.URL}, server.Client())

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

	client := NewClientWithHTTPClient(config.AIAgentConfig{ChatServiceURL: server.URL}, server.Client())

	got, err := client.RetrieveChatResponse(context.Background(), "jwt", req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Response != "hello" || len(got.Suggestions) != 1 {
		t.Errorf("unexpected result: %+v", got)
	}
}
