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

// testConnID is a well-formed connection id. user_connection.id is a uuid
// column, so the handlers reject anything else before it can reach a 22P02
// cast error in the repository.
const testConnID = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

// fakeConnectionReader records what each transition was called with, so the
// tests can assert the property that motivated the redesign: the caller's
// identity always comes from the JWT and the row id always from the path,
// never from a payload.
type fakeConnectionReader struct {
	info   models.UserConnectionsInfo
	getErr error

	requestConn   models.Connection
	requestErr    error
	requestCalls  int
	requestedWith struct{ requesterUUID, addresseeUUID string }

	acceptConn   models.Connection
	acceptErr    error
	acceptCalls  int
	acceptedWith struct{ connectionID, callerUUID string }

	deleteErr   error
	deleteCalls int
	deletedWith struct{ connectionID, callerUUID string }
}

func (f *fakeConnectionReader) Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error) {
	return f.info, f.getErr
}

func (f *fakeConnectionReader) Request(ctx context.Context, requesterUUID, addresseeUUID string) (models.Connection, error) {
	f.requestCalls++
	f.requestedWith.requesterUUID = requesterUUID
	f.requestedWith.addresseeUUID = addresseeUUID
	return f.requestConn, f.requestErr
}

func (f *fakeConnectionReader) Accept(ctx context.Context, connectionID, callerUUID string) (models.Connection, error) {
	f.acceptCalls++
	f.acceptedWith.connectionID = connectionID
	f.acceptedWith.callerUUID = callerUUID
	return f.acceptConn, f.acceptErr
}

func (f *fakeConnectionReader) Delete(ctx context.Context, connectionID, callerUUID string) error {
	f.deleteCalls++
	f.deletedWith.connectionID = connectionID
	f.deletedWith.callerUUID = callerUUID
	return f.deleteErr
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
	r.POST("/users/me/connections/:id/accept", h.Accept)
	r.DELETE("/users/me/connections/:id", h.Delete)
	return r
}

// bobProfile is the target/other party in most of the tests below.
func bobProfile() *fakeAttendeeRepo {
	return &fakeAttendeeRepo{byUUID: map[string]models.Attendee{
		"user-2": {
			ID: "attendee-2", Email: "bob@example.com", FirstName: "Bob", LastName: "Receiver",
			ProfileURL: "https://example.com/bob", Title: "Engineer", Company: "Acme", Country: "LK",
		},
	}}
}

func TestConnectionHandler_AllRoutes_Unauthenticated(t *testing.T) {
	for _, tc := range []struct {
		name, method, path string
		body               any
	}{
		{"get", http.MethodGet, "/users/me/connections", nil},
		{"create", http.MethodPost, "/users/me/connections", models.ConnectionRequest{TargetID: "user-2"}},
		{"accept", http.MethodPost, "/users/me/connections/" + testConnID + "/accept", nil},
		{"delete", http.MethodDelete, "/users/me/connections/" + testConnID, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader := &fakeConnectionReader{}
			h := NewConnectionHandler(reader, &fakeAttendeeRepo{})
			r := newConnectionTestRouter(h, nil)

			w := doRequest(r, tc.method, tc.path, tc.body)
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusUnauthorized, w.Body.String())
			}
			if reader.requestCalls+reader.acceptCalls+reader.deleteCalls != 0 {
				t.Errorf("repository was called without an authenticated caller: %+v", reader)
			}
		})
	}
}

func TestConnectionHandler_Get_ReturnsInfo(t *testing.T) {
	reader := &fakeConnectionReader{info: models.UserConnectionsInfo{
		Connections: []models.ConnectionUserInfo{{ConnectionID: testConnID, UserID: "user-2", Name: "Bob Receiver"}},
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
	if len(got.Connections) != 1 || got.Connections[0].UserID != "user-2" || got.Connections[0].ConnectionID != testConnID {
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

func TestConnectionHandler_Create_RequesterIsTheJWTSub(t *testing.T) {
	// The whole point of the redesign: the requester is the token's subject
	// and the addressee is the body's targetId, in that order and never the
	// other way round. A body that names a requester cannot be honoured
	// because ConnectionRequest has nowhere to put one.
	reader := &fakeConnectionReader{requestConn: models.Connection{
		ID: testConnID, RequesterID: testUser.UserID, AddresseeID: "user-2", State: models.ConnectionPending,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", map[string]any{
		"targetId":    "user-2",
		"requesterId": "someone-else",
		"userId":      "someone-else",
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if reader.requestCalls != 1 {
		t.Fatalf("Request called %d times, want 1", reader.requestCalls)
	}
	if reader.requestedWith.requesterUUID != testUser.UserID {
		t.Errorf("requester = %q, want the JWT sub %q", reader.requestedWith.requesterUUID, testUser.UserID)
	}
	if reader.requestedWith.addresseeUUID != "user-2" {
		t.Errorf("addressee = %q, want the body's targetId %q", reader.requestedWith.addresseeUUID, "user-2")
	}
}

func TestConnectionHandler_Create_MissingTargetIDIsRejected(t *testing.T) {
	for _, tc := range []struct {
		name string
		body any
	}{
		{"absent", map[string]any{}},
		{"empty", map[string]any{"targetId": ""}},
		{"whitespace", map[string]any{"targetId": "   "}},
		{"null", map[string]any{"targetId": nil}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader := &fakeConnectionReader{}
			h := NewConnectionHandler(reader, bobProfile())
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/me/connections", tc.body)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
			}
			if reader.requestCalls != 0 {
				t.Errorf("Request called %d times, want 0", reader.requestCalls)
			}
		})
	}
}

func TestConnectionHandler_Create_MalformedJSONIsRejected(t *testing.T) {
	reader := &fakeConnectionReader{}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	// A JSON string where an object is expected: well-formed JSON that cannot
	// bind, which is the shape a bad client actually sends.
	w := doRequest(r, http.MethodPost, "/users/me/connections", "not-an-object")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if reader.requestCalls != 0 {
		t.Errorf("Request called %d times, want 0", reader.requestCalls)
	}
}

func TestConnectionHandler_Create_RepoErrorsMapToStatuses(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		{"self connection", repository.ErrSelfConnection, http.StatusBadRequest},
		{"unknown attendee", repository.ErrNotFound, http.StatusNotFound},
		{"unexpected", errBoom, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := NewConnectionHandler(&fakeConnectionReader{requestErr: tc.err}, bobProfile())
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/me/connections", models.ConnectionRequest{TargetID: "user-2"})
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, tc.want, w.Body.String())
			}
		})
	}
}

func TestConnectionHandler_Create_ReturnsEnrichedTargetInfo(t *testing.T) {
	reader := &fakeConnectionReader{requestConn: models.Connection{
		ID: testConnID, RequesterID: testUser.UserID, AddresseeID: "user-2", State: models.ConnectionPending,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.ConnectionRequest{TargetID: "user-2"})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}

	var got models.ConnectionUserInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	// connectionId is what the accept and delete routes address; without it
	// the client has no way to name the row it just created.
	//
	// Email is expected empty even though bobProfile() supplies one: the
	// connection this route creates is pending, and the address is what
	// accepting exchanges. See TestConnectionHandler_Create_PendingBodyHasNoEmailKey.
	want := models.ConnectionUserInfo{
		ConnectionID: testConnID,
		UserID:       "user-2",
		Name:         "Bob Receiver",
		Status:       "pending",
		ProfileURL:   "https://example.com/bob",
		Title:        "Engineer",
		Company:      "Acme",
		Country:      "LK",
	}
	if got != want {
		t.Errorf("body = %+v, want %+v", got, want)
	}
}

func TestConnectionHandler_Create_PendingBodyHasNoEmailKey(t *testing.T) {
	// The 201 body used to carry the target's address, so sending a request to
	// anyone disclosed their email with no action on their part. The assertion
	// is on the decoded map rather than on ConnectionUserInfo, because
	// unmarshalling into the struct turns an absent key and an empty string
	// into the same zero value -- and "" is what a regression that blanks the
	// field instead of omitting it would produce.
	reader := &fakeConnectionReader{requestConn: models.Connection{
		ID: testConnID, RequesterID: testUser.UserID, AddresseeID: "user-2", State: models.ConnectionPending,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.ConnectionRequest{TargetID: "user-2"})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}

	var got map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got["status"] != "pending" {
		t.Fatalf("status = %v, want %q -- the rest of this test only means something on a pending row", got["status"], "pending")
	}
	if v, ok := got["email"]; ok {
		t.Errorf("body carries email = %#v on a pending connection, want the key absent; body: %s", v, w.Body.String())
	}
	// The profile is still enriched -- this withholds the address specifically,
	// it does not degrade the response to bare ids.
	if got["name"] != "Bob Receiver" {
		t.Errorf("name = %v, want %q", got["name"], "Bob Receiver")
	}
	if got["company"] != "Acme" {
		t.Errorf("company = %v, want %q", got["company"], "Acme")
	}
}

func TestConnectionHandler_Accept_AcceptedBodyCarriesEmail(t *testing.T) {
	// Accepting is precisely the act that exchanges contact details, so the
	// 200 body must carry the other party's address. Asserted on the decoded
	// map for the same absent-vs-empty reason as the Create case above.
	reader := &fakeConnectionReader{acceptConn: models.Connection{
		ID: testConnID, RequesterID: "user-2", AddresseeID: testUser.UserID, State: models.ConnectionAccepted,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections/"+testConnID+"/accept", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got["status"] != "accepted" {
		t.Fatalf("status = %v, want %q", got["status"], "accepted")
	}
	if got["email"] != "bob@example.com" {
		t.Errorf("email = %v, want %q on an accepted connection; body: %s", got["email"], "bob@example.com", w.Body.String())
	}
}

func TestConnectionHandler_Create_IgnoresAnyStateInTheBody(t *testing.T) {
	// The redesign's central claim: there is no payload that reaches an
	// accepted state through this route. Whatever state-shaped fields the
	// body carries, the handler still calls Request and the response still
	// reports whatever state the repository wrote.
	reader := &fakeConnectionReader{requestConn: models.Connection{
		ID: testConnID, RequesterID: testUser.UserID, AddresseeID: "user-2", State: models.ConnectionPending,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", map[string]any{
		"targetId": "user-2",
		"status":   "accepted",
		"state":    "accepted",
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if reader.requestCalls != 1 || reader.acceptCalls != 0 {
		t.Fatalf("Request/Accept called %d/%d times, want 1/0", reader.requestCalls, reader.acceptCalls)
	}

	var got models.ConnectionUserInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.Status != "pending" {
		t.Errorf("Status = %q, want %q -- a body must not be able to name a state", got.Status, "pending")
	}
}

func TestConnectionHandler_Create_ProfileLookupFailureStillReports201(t *testing.T) {
	// The write has already committed by the time the profile is fetched, so
	// failing the response would tell the client nothing happened when in
	// fact the request was created.
	reader := &fakeConnectionReader{requestConn: models.Connection{
		ID: testConnID, RequesterID: testUser.UserID, AddresseeID: "user-2", State: models.ConnectionPending,
	}}
	h := NewConnectionHandler(reader, &fakeAttendeeRepo{getErr: errBoom})
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections", models.ConnectionRequest{TargetID: "user-2"})
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}

	var got models.ConnectionUserInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.ConnectionID != testConnID || got.UserID != "user-2" || got.Status != "pending" {
		t.Errorf("body = %+v, want the ids and status the handler already knew", got)
	}
}

func TestConnectionHandler_Accept_UsesPathIDAndJWTSub(t *testing.T) {
	reader := &fakeConnectionReader{acceptConn: models.Connection{
		ID: testConnID, RequesterID: "user-2", AddresseeID: testUser.UserID, State: models.ConnectionAccepted,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections/"+testConnID+"/accept", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if reader.acceptCalls != 1 {
		t.Fatalf("Accept called %d times, want 1", reader.acceptCalls)
	}
	if reader.acceptedWith.connectionID != testConnID {
		t.Errorf("connectionID = %q, want the path id %q", reader.acceptedWith.connectionID, testConnID)
	}
	if reader.acceptedWith.callerUUID != testUser.UserID {
		t.Errorf("caller = %q, want the JWT sub %q", reader.acceptedWith.callerUUID, testUser.UserID)
	}
}

func TestConnectionHandler_Accept_NonUUIDIsRejected(t *testing.T) {
	reader := &fakeConnectionReader{}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections/not-a-uuid/accept", nil)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if reader.acceptCalls != 0 {
		t.Errorf("Accept called %d times, want 0", reader.acceptCalls)
	}
}

func TestConnectionHandler_Accept_RepoErrorsMapToStatuses(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		// The requester trying to accept their own request: the bug the
		// route split exists to make unreachable.
		{"not the addressee", repository.ErrConnectionForbidden, http.StatusForbidden},
		{"already accepted", repository.ErrConnectionNotPending, http.StatusConflict},
		{"no such connection", repository.ErrNotFound, http.StatusNotFound},
		{"unexpected", errBoom, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := NewConnectionHandler(&fakeConnectionReader{acceptErr: tc.err}, bobProfile())
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/users/me/connections/"+testConnID+"/accept", nil)
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, tc.want, w.Body.String())
			}
		})
	}
}

func TestConnectionHandler_Accept_ReturnsRequesterProfile(t *testing.T) {
	// The caller is the addressee here, so the other party -- the one the
	// response describes -- is the requester.
	reader := &fakeConnectionReader{acceptConn: models.Connection{
		ID: testConnID, RequesterID: "user-2", AddresseeID: testUser.UserID, State: models.ConnectionAccepted,
	}}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/me/connections/"+testConnID+"/accept", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got models.ConnectionUserInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	want := models.ConnectionUserInfo{
		ConnectionID: testConnID,
		UserID:       "user-2",
		Name:         "Bob Receiver",
		Email:        "bob@example.com",
		Status:       "accepted",
		ProfileURL:   "https://example.com/bob",
		Title:        "Engineer",
		Company:      "Acme",
		Country:      "LK",
	}
	if got != want {
		t.Errorf("body = %+v, want %+v", got, want)
	}
}

func TestConnectionHandler_Delete_ReturnsNoContent(t *testing.T) {
	reader := &fakeConnectionReader{}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodDelete, "/users/me/connections/"+testConnID, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusNoContent, w.Body.String())
	}
	if w.Body.Len() != 0 {
		t.Errorf("body = %q, want empty", w.Body.String())
	}
	if reader.deletedWith.connectionID != testConnID || reader.deletedWith.callerUUID != testUser.UserID {
		t.Errorf("Delete called with (%q, %q), want (%q, %q)",
			reader.deletedWith.connectionID, reader.deletedWith.callerUUID, testConnID, testUser.UserID)
	}
}

func TestConnectionHandler_Delete_NonUUIDIsRejected(t *testing.T) {
	reader := &fakeConnectionReader{}
	h := NewConnectionHandler(reader, bobProfile())
	r := newConnectionTestRouter(h, testUser)

	w := doRequest(r, http.MethodDelete, "/users/me/connections/not-a-uuid", nil)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if reader.deleteCalls != 0 {
		t.Errorf("Delete called %d times, want 0", reader.deleteCalls)
	}
}

func TestConnectionHandler_Delete_RepoErrorsMapToStatuses(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		{"no such connection", repository.ErrNotFound, http.StatusNotFound},
		{"unexpected", errBoom, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := NewConnectionHandler(&fakeConnectionReader{deleteErr: tc.err}, bobProfile())
			r := newConnectionTestRouter(h, testUser)

			w := doRequest(r, http.MethodDelete, "/users/me/connections/"+testConnID, nil)
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d, body: %s", w.Code, tc.want, w.Body.String())
			}
		})
	}
}
