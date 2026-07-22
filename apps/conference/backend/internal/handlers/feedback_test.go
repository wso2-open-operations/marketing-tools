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
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

type fakeFeedbackReader struct {
	insertErr error
	inserted  models.FeedbackInsert
}

func (f *fakeFeedbackReader) Insert(ctx context.Context, in models.FeedbackInsert) error {
	f.inserted = in
	return f.insertErr
}

func newFeedbackTestRouter(h *FeedbackHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.POST("/feedback", h.Create)
	return r
}

func TestFeedbackHandler_Create_Unauthenticated(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{}, &fakeEventReader{})
	r := newFeedbackTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{FeedbackType: models.FeedbackEvent, Rating: 5})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestFeedbackHandler_Create_SessionFeedbackWithSessionID(t *testing.T) {
	feedback := &fakeFeedbackReader{}
	h := NewFeedbackHandler(feedback, &fakeEventReader{})
	r := newFeedbackTestRouter(h, testUser)

	sessionID := "session-1"
	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		SessionID: &sessionID, Rating: 5, FeedbackType: models.FeedbackSession,
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if w.Body.Len() != 0 {
		t.Errorf("body = %q, want empty (matches old http:Created with no payload)", w.Body.String())
	}
	if feedback.inserted.UserUUID != testUser.UserID {
		t.Errorf("UserUUID = %q, want %q", feedback.inserted.UserUUID, testUser.UserID)
	}
	if feedback.inserted.SessionID == nil || *feedback.inserted.SessionID != sessionID {
		t.Errorf("SessionID = %v, want %q", feedback.inserted.SessionID, sessionID)
	}
	if feedback.inserted.EventID != nil {
		t.Errorf("EventID = %v, want nil", feedback.inserted.EventID)
	}
}

func TestFeedbackHandler_Create_EventFeedbackUsesCurrentEvent(t *testing.T) {
	feedback := &fakeFeedbackReader{}
	events := &fakeEventReader{events: []models.Event{
		{ID: "current-event", Name: "WSO2Con Africa", IsCurrent: true},
		{ID: "older-event", Name: "WSO2Con NA"},
	}}
	h := NewFeedbackHandler(feedback, events)
	r := newFeedbackTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		Rating: 4, FeedbackType: models.FeedbackEvent,
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if feedback.inserted.EventID == nil || *feedback.inserted.EventID != "current-event" {
		t.Errorf("EventID = %v, want %q", feedback.inserted.EventID, "current-event")
	}
	if feedback.inserted.SessionID != nil {
		t.Errorf("SessionID = %v, want nil", feedback.inserted.SessionID)
	}
}

func TestFeedbackHandler_Create_SessionFeedbackWithoutSessionIDIs400(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{}, &fakeEventReader{})
	r := newFeedbackTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		Rating: 5, FeedbackType: models.FeedbackSession,
	})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d (old code returned 500 here; fixed per .claude/PLAN.md)", w.Code, http.StatusBadRequest)
	}
}

func TestFeedbackHandler_Create_InvalidFeedbackTypeIs400(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{}, &fakeEventReader{})
	r := newFeedbackTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		Rating: 5, FeedbackType: models.FeedbackType("BOGUS"),
	})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestFeedbackHandler_Create_MalformedBodyIs400(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{}, &fakeEventReader{})
	r := newFeedbackTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/feedback", bytes.NewBufferString("{not json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestFeedbackHandler_Create_RepoErrorMapsTo500(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{insertErr: errBoom}, &fakeEventReader{})
	r := newFeedbackTestRouter(h, testUser)

	sessionID := "session-1"
	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		SessionID: &sessionID, Rating: 5, FeedbackType: models.FeedbackSession,
	})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestFeedbackHandler_Create_NoCurrentEventMapsTo500(t *testing.T) {
	h := NewFeedbackHandler(&fakeFeedbackReader{}, &fakeEventReader{events: []models.Event{}})
	r := newFeedbackTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/feedback", models.FeedbackRequest{
		Rating: 4, FeedbackType: models.FeedbackEvent,
	})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}
