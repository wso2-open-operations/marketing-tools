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
	"strings"
	"testing"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

func TestAIAgentHandler_PersonalizedProfile_Unauthenticated(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
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
			h := NewAIAgentHandler(client, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
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
	h := NewAIAgentHandler(&fakeAIAgentClient{profileErr: errBoom}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/profile", models.PersonalizeAgentUserProfile{})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAIAgentHandler_PersonalizedProfile_MalformedBody_Returns400(t *testing.T) {
	h := NewAIAgentHandler(&fakeAIAgentClient{}, &fakeAttendeeRepo{}, config.AIFeatureStatus{})
	r := newAIAgentTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/users/profile", strings.NewReader("{not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}
