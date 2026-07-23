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

func TestAIAgentHandler_Chat_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAIAgentHandler_Chat_MalformedBody_Returns400(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/assistant/chat", bytes.NewBufferString("{not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestAIAgentHandler_Chat_ClientError_Returns500(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{chatErr: errBoom}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/assistant/chat", models.ChatRequest{Question: "hi"})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_Chat_ForwardsRequestVerbatimAndReturns201(t *testing.T) {
	client := &fakeAIAgentClient{chatResp: &models.ChatResponse{Response: "hello", Suggestions: []string{"s1"}}}
	h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	req := models.ChatRequest{
		History:  []models.ChatHistory{{Question: "q1", Answer: "a1"}},
		Question: "q2",
	}
	w := doRequest(r, http.MethodPost, "/assistant/chat", req)
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}

	if client.chatReqSeen.Question != "q2" || len(client.chatReqSeen.History) != 1 || client.chatReqSeen.History[0].Question != "q1" {
		t.Errorf("request not forwarded verbatim: %+v", client.chatReqSeen)
	}

	var got models.ChatResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got.Response != "hello" || len(got.Suggestions) != 1 {
		t.Errorf("unexpected response: %+v", got)
	}
}
