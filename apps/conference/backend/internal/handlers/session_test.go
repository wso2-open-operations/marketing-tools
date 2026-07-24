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

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

type fakeSessionReader struct {
	session    models.Session
	sessionErr error
	current    []models.Session
	currentErr error
}

func (f *fakeSessionReader) GetSession(ctx context.Context, id string) (models.Session, error) {
	return f.session, f.sessionErr
}

func (f *fakeSessionReader) GetCurrentSessions(ctx context.Context) ([]models.Session, error) {
	return f.current, f.currentErr
}

func newSessionTestRouter(h *SessionHandler) *gin.Engine {
	r := gin.New()
	r.GET("/sessions/current", h.Current)
	r.GET("/sessions/:id", h.Get)
	return r
}

func TestSessionHandler_Get_ReturnsSession(t *testing.T) {
	reader := &fakeSessionReader{session: models.Session{ID: "session-1", Title: "Intro to WSO2"}}
	h := NewSessionHandler(reader)
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/session-1", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got models.Session
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.ID != "session-1" {
		t.Errorf("ID = %q, want %q", got.ID, "session-1")
	}
}

func TestSessionHandler_Get_NotFoundReturns404(t *testing.T) {
	h := NewSessionHandler(&fakeSessionReader{sessionErr: repository.ErrNotFound})
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/missing", nil)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestSessionHandler_Get_OtherErrorReturns500(t *testing.T) {
	h := NewSessionHandler(&fakeSessionReader{sessionErr: errBoom})
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/session-1", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

func TestSessionHandler_Current_ReturnsSessions(t *testing.T) {
	reader := &fakeSessionReader{
		current: []models.Session{
			{ID: "session-1", Kind: "session", Title: "Intro to WSO2"},
		},
	}
	h := NewSessionHandler(reader)
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/current", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got []models.Session
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got) != 1 || got[0].ID != "session-1" {
		t.Errorf("unexpected body: %+v", got)
	}
}

func TestSessionHandler_Current_EmptyResultReturnsEmptyArrayNotNull(t *testing.T) {
	h := NewSessionHandler(&fakeSessionReader{current: nil})
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/current", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if body := rec.Body.String(); body != "[]" {
		t.Errorf("body = %q, want %q", body, "[]")
	}
}

func TestSessionHandler_Current_RepositoryErrorReturns500(t *testing.T) {
	h := NewSessionHandler(&fakeSessionReader{currentErr: errBoom})
	rec := doRequest(newSessionTestRouter(h), http.MethodGet, "/sessions/current", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}
