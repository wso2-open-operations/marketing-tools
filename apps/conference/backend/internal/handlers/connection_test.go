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
	"wso2-coin-backend/internal/repository"
)

type fakeConnectionReader struct {
	info         models.UserConnectionsInfo
	getErr       error
	upsertErr    error
	existing     *models.Connection
	findErr      error
	upsertCalls  int
	upsertedWith struct {
		initiatorUUID, recipientUUID string
		status                       models.ConnectionStatus
	}
}

func (f *fakeConnectionReader) Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error) {
	return f.info, f.getErr
}

func (f *fakeConnectionReader) Find(ctx context.Context, aUUID, bUUID string) (models.Connection, error) {
	if f.findErr != nil {
		return models.Connection{}, f.findErr
	}
	if f.existing == nil {
		return models.Connection{}, repository.ErrNotFound
	}
	return *f.existing, nil
}

func (f *fakeConnectionReader) Upsert(ctx context.Context, initiatorUUID, recipientUUID string, status models.ConnectionStatus) error {
	f.upsertCalls++
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
		"user-2": {
			ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob", LastName: "Receiver",
			ProfileURL: "https://example.com/bob", Title: "Engineer", Company: "Acme", Country: "LK",
		},
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
	// Parity with GET: POST must return the enriched fields it already fetched.
	if got.Status != "pending" {
		t.Errorf("Status = %q, want %q", got.Status, "pending")
	}
	if got.ProfileURL != "https://example.com/bob" {
		t.Errorf("ProfileURL = %q, want it echoed from the fetched attendee", got.ProfileURL)
	}
	if got.Title != "Engineer" || got.Company != "Acme" || got.Country != "LK" {
		t.Errorf("title/company/country = %q/%q/%q, want Engineer/Acme/LK", got.Title, got.Company, got.Country)
	}
}

func TestConnectionHandler_Create_NotFoundWhenTargetHasNoAttendeeRow(t *testing.T) {
	h := NewConnectionHandler(&fakeConnectionReader{}, &fakeAttendeeRepo{byUUID: map[string]models.Attendee{}})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "missing-user", Status: models.ConnectionPending})
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusNotFound, w.Body.String())
	}
}

func TestConnectionHandler_Create_UpsertErrorMapsTo500(t *testing.T) {
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob"},
	}}
	h := NewConnectionHandler(&fakeConnectionReader{upsertErr: errBoom}, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionPending})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

// --- A3: authorization + ordering on POST /users/me/connections ---

func TestConnectionHandler_Create_RejectsSelfConnection(t *testing.T) {
	connReader := &fakeConnectionReader{}
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		testUser.UserID: {ID: "attendee-1", Email: "alice@example.com", FirstName: "Alice"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: testUser.UserID, Status: models.ConnectionPending})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if connReader.upsertCalls != 0 {
		t.Errorf("Upsert called %d times, want 0 for a self-connection", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_RequesterCannotAcceptOwnRequest(t *testing.T) {
	// The caller is the initiator of an existing pending request; accepting
	// it themselves would put them in the target's connections[] with zero
	// action by the target.
	connReader := &fakeConnectionReader{existing: &models.Connection{
		InitiatorID: testUser.UserID, RecipientID: "user-2", Status: models.ConnectionPending,
	}}
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob", LastName: "Receiver"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionAccepted})
	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusForbidden, w.Body.String())
	}
	if connReader.upsertCalls != 0 {
		t.Errorf("Upsert called %d times, want 0 when the requester accepts their own request", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_TargetMayAcceptPendingRequest(t *testing.T) {
	// Mirror image of the above: the caller is the recipient, so accepting is legal.
	connReader := &fakeConnectionReader{existing: &models.Connection{
		InitiatorID: "user-2", RecipientID: testUser.UserID, Status: models.ConnectionPending,
	}}
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob", LastName: "Receiver"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionAccepted})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if connReader.upsertCalls != 1 {
		t.Errorf("Upsert called %d times, want 1", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_AcceptWithNoPendingRequestIsRejected(t *testing.T) {
	connReader := &fakeConnectionReader{} // no existing row
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionAccepted})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if connReader.upsertCalls != 0 {
		t.Errorf("Upsert called %d times, want 0", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_RecipientCannotReopenRequestAsSender(t *testing.T) {
	// The consent bypass: Upsert reuses the stored direction, so a pending
	// write by the stored recipient rewrites the row as if the initiator had
	// sent it again -- which the recipient could then legally accept, landing
	// a connection the initiator had explicitly withdrawn or never re-sent.
	for _, tc := range []struct {
		name   string
		status models.ConnectionStatus
	}{
		{"withdrawn request", models.ConnectionRejected},
		{"already accepted", models.ConnectionAccepted},
	} {
		t.Run(tc.name, func(t *testing.T) {
			connReader := &fakeConnectionReader{existing: &models.Connection{
				InitiatorID: "user-2", RecipientID: testUser.UserID, Status: tc.status,
			}}
			attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
				"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob"},
			}}
			h := NewConnectionHandler(connReader, attendees)
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/me/connections",
				models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionPending})
			if w.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusForbidden, w.Body.String())
			}
			if connReader.upsertCalls != 0 {
				t.Errorf("Upsert called %d times, want 0 when the recipient re-opens a request", connReader.upsertCalls)
			}
		})
	}
}

func TestConnectionHandler_Create_SenderMayResendOwnRequest(t *testing.T) {
	// Mirror image: the caller is the stored initiator, so re-sending a
	// request they withdrew themselves stays legal.
	connReader := &fakeConnectionReader{existing: &models.Connection{
		InitiatorID: testUser.UserID, RecipientID: "user-2", Status: models.ConnectionRejected,
	}}
	attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob"},
	}}
	h := NewConnectionHandler(connReader, attendees)
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionPending})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if connReader.upsertCalls != 1 {
		t.Errorf("Upsert called %d times, want 1", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_EitherPartyMayDecline(t *testing.T) {
	for _, tc := range []struct {
		name     string
		existing models.Connection
	}{
		{"recipient declines", models.Connection{InitiatorID: "user-2", RecipientID: testUser.UserID, Status: models.ConnectionPending}},
		{"initiator withdraws", models.Connection{InitiatorID: testUser.UserID, RecipientID: "user-2", Status: models.ConnectionPending}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			existing := tc.existing
			connReader := &fakeConnectionReader{existing: &existing}
			attendees := &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
				"user-2": {ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob"},
			}}
			h := NewConnectionHandler(connReader, attendees)
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/me/connections",
				models.UserConnectionRequest{UserID: "user-2", Status: models.ConnectionRejected})
			if w.Code != http.StatusCreated {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
			}
		})
	}
}

func TestConnectionHandler_Create_MissingUserIDIsRejected(t *testing.T) {
	connReader := &fakeConnectionReader{}
	h := NewConnectionHandler(connReader, &fakeAttendeeRepo{})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "", Status: models.ConnectionPending})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if connReader.upsertCalls != 0 {
		t.Errorf("Upsert called %d times, want 0", connReader.upsertCalls)
	}
}

func TestConnectionHandler_Create_UnknownTargetWritesNothing(t *testing.T) {
	// The orphan-row defect: the row used to be written before the target
	// was validated, so a 404'd request left a phantom pending request.
	connReader := &fakeConnectionReader{}
	h := NewConnectionHandler(connReader, &fakeAttendeeRepo{byUUID: map[string]models.Attendee{}})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections",
		models.UserConnectionRequest{UserID: "missing-user", Status: models.ConnectionPending})
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusNotFound, w.Body.String())
	}
	if connReader.upsertCalls != 0 {
		t.Errorf("Upsert called %d times, want 0 -- a 404'd request must leave no row", connReader.upsertCalls)
	}
}
