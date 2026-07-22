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

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

type fakeConnectionReader struct {
	info         models.UserConnectionsInfo
	getErr       error
	upsertErr    error
	upsertedWith struct {
		initiatorUUID, recipientUUID string
		status                       models.ConnectionStatus
	}
}

func (f *fakeConnectionReader) Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error) {
	return f.info, f.getErr
}

func (f *fakeConnectionReader) Upsert(ctx context.Context, initiatorUUID, recipientUUID string, status models.ConnectionStatus) error {
	f.upsertedWith.initiatorUUID = initiatorUUID
	f.upsertedWith.recipientUUID = recipientUUID
	f.upsertedWith.status = status
	return f.upsertErr
}

func newConnectionTestRouter(h *ConnectionHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.GET("/users/me/connections", h.Get)
	r.POST("/users/me/connections", h.Create)
	return r
}

func TestConnectionHandler_Get_Unauthenticated(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{}, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/users/me/connections", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestConnectionHandler_Get_ReturnsInfo(t *testing.T) {
	reader := &fakeConnectionReader{info: models.UserConnectionsInfo{
		Connections: []models.ConnectionUserInfo{{UserID: "user-2", Name: "Bob"}},
	}}
	h := NewConnectionHandler(reader, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/users/me/connections", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got models.UserConnectionsInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got.Connections) != 1 || got.Connections[0].UserID != "user-2" {
		t.Errorf("unexpected body: %+v", got)
	}
}

func TestConnectionHandler_Get_RepoErrorMapsTo500(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{getErr: errBoom}, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/users/me/connections", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestConnectionHandler_Create_Unauthenticated(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{}, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "user-2"})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestConnectionHandler_Create_UpsertsAndReturnsTargetInfo(t *testing.T) {
	connReader := &fakeConnectionReader{}
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob", LastName: "Receiver"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionPending})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if connReader.upsertedWith.initiatorUUID != testUser.UserID || connReader.upsertedWith.recipientUUID != "user-2" {
		t.Errorf("Upsert called with (%q, %q), want (%q, %q)",
			connReader.upsertedWith.initiatorUUID, connReader.upsertedWith.recipientUUID, testUser.UserID, "user-2")
	}

	var got models.ConnectionUserInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.Name != "Bob Receiver" {
		t.Errorf("Name = %q, want %q", got.Name, "Bob Receiver")
	}
	if got.Email != "bob@example.com" {
		t.Errorf("Email = %q, want %q", got.Email, "bob@example.com")
	}
}

func TestConnectionHandler_Create_NotFoundWhenTargetHasNoAttendeeRow(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{}, &fakeAttendeeRepo{byUUID: map[string]models.Attendee{}})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "missing-user"})
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusNotFound, w.Body.String())
	}
}

func TestConnectionHandler_Create_UpsertErrorMapsTo500(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{upsertErr: errBoom}, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "user-2"})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}
