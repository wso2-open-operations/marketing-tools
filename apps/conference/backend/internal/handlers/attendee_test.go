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

type fakeAttendeeRepo struct {
	insertErr    error
	insertCalls  int
	insertedWith struct {
		payload models.AttendeeInsert
		email   string
		idpUUID string
	}

	byEmail     map[string]models.Attendee
	byUUID      map[string]models.Attendee
	getErr      error
	patchErr    error
	patchedWith struct {
		email     string
		patch     models.AttendeePatch
		updatedBy string
	}

	searchResult models.AttendeeSearchResult
	searchErr    error
}

func (f *fakeAttendeeRepo) Insert(ctx context.Context, payload models.AttendeeInsert, email, idpUUID string) error {
	f.insertCalls++
	f.insertedWith.payload = payload
	f.insertedWith.email = email
	f.insertedWith.idpUUID = idpUUID
	return f.insertErr
}

func (f *fakeAttendeeRepo) GetByEmail(ctx context.Context, email string) (models.Attendee, error) {
	if f.getErr != nil {
		return models.Attendee{}, f.getErr
	}
	a, ok := f.byEmail[email]
	if !ok {
		return models.Attendee{}, repository.ErrNotFound
	}
	return a, nil
}

func (f *fakeAttendeeRepo) GetByUUID(ctx context.Context, idpUUID string) (models.Attendee, error) {
	if f.getErr != nil {
		return models.Attendee{}, f.getErr
	}
	a, ok := f.byUUID[idpUUID]
	if !ok {
		return models.Attendee{}, repository.ErrNotFound
	}
	return a, nil
}

func (f *fakeAttendeeRepo) PatchByEmail(ctx context.Context, email string, patch models.AttendeePatch, updatedBy string) error {
	f.patchedWith.email = email
	f.patchedWith.patch = patch
	f.patchedWith.updatedBy = updatedBy
	return f.patchErr
}

func (f *fakeAttendeeRepo) Search(ctx context.Context, filter models.AttendeeSearchFilter, excludedUUID string) (models.AttendeeSearchResult, error) {
	return f.searchResult, f.searchErr
}

func newAttendeeTestRouter(h *AttendeeHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.POST("/attendees", h.Create)
	r.PATCH("/attendees", h.Patch)
	r.GET("/attendees/me", h.Me)
	r.GET("/user-profile", h.Profile)
	r.POST("/attendees/search", h.Search)
	return r
}

func TestAttendeeHandler_Create_UsesJWTSubAndEmailNotBody(t *testing.T) {
	repo := &fakeAttendeeRepo{}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	// A body `email` is decoded into nothing and must not reach the repo.
	w := doRequest(r, http.MethodPost, "/attendees", map[string]any{
		"email": "victim@example.com", "firstName": "Ada", "lastName": "Lovelace",
	})

	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	if repo.insertedWith.idpUUID != testUser.UserID {
		t.Errorf("Insert called with idpUUID = %q, want %q (the JWT sub, not any body field)", repo.insertedWith.idpUUID, testUser.UserID)
	}
	if repo.insertedWith.email != testUser.Email {
		t.Errorf("Insert called with email = %q, want %q (the JWT email, not any body field)", repo.insertedWith.email, testUser.Email)
	}
}

func TestAttendeeHandler_Create_Unauthenticated(t *testing.T) {
	h := NewAttendeeHandler(&fakeAttendeeRepo{})
	r := newAttendeeTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/attendees", models.AttendeeInsert{FirstName: "Ada", LastName: "Lovelace"})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAttendeeHandler_Create_RepoErrorMapsTo500(t *testing.T) {
	repo := &fakeAttendeeRepo{insertErr: errBoom}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees", models.AttendeeInsert{FirstName: "Ada", LastName: "Lovelace"})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestAttendeeHandler_Patch_UpdatesAndReturnsAttendee(t *testing.T) {
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		testUser.Email: {ID: "attendee-1", Email: testUser.Email, Title: "Old Title"},
	}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	title := "New Title"
	w := doRequest(r, http.MethodPatch, "/attendees", models.AttendeePatch{Title: &title})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if repo.patchedWith.updatedBy != testUser.UserID {
		t.Errorf("PatchByEmail called with updatedBy = %q, want %q (the JWT sub)", repo.patchedWith.updatedBy, testUser.UserID)
	}
}

func TestAttendeeHandler_Me_NotFound(t *testing.T) {
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/attendees/me", nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestAttendeeHandler_Me_ReturnsAttendee(t *testing.T) {
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		testUser.Email: {ID: "attendee-1", Email: testUser.Email},
	}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/attendees/me", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
}

func TestAttendeeHandler_Profile_NotFoundWhenNoAttendeeRow(t *testing.T) {
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/user-profile", nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestAttendeeHandler_Profile_ReturnsProfileShape(t *testing.T) {
	user := &middleware.UserInfo{Email: "ada@example.com", UserID: "user-1", GivenName: "Ada", FamilyName: "Lovelace"}
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		"ada@example.com": {ID: "attendee-1", Email: "ada@example.com", QRUri: "WCabcdef", IsPartner: true},
	}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, user)

	w := doRequest(r, http.MethodGet, "/user-profile", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got models.Profile
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.Username != "Ada Lovelace" {
		t.Errorf("Username = %q, want %q", got.Username, "Ada Lovelace")
	}
	if got.QRUri != "WCabcdef" {
		t.Errorf("QRUri = %q, want %q", got.QRUri, "WCabcdef")
	}
	if !got.IsPartner {
		t.Errorf("IsPartner = false, want true")
	}
	if got.ImageURL != defaultProfileImageURL {
		t.Errorf("ImageURL = %q, want the hardcoded default %q", got.ImageURL, defaultProfileImageURL)
	}
}

func TestAttendeeHandler_Search_Unauthenticated(t *testing.T) {
	h := NewAttendeeHandler(&fakeAttendeeRepo{})
	r := newAttendeeTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/attendees/search", map[string]any{})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAttendeeHandler_Search_ReturnsEnvelope(t *testing.T) {
	repo := &fakeAttendeeRepo{searchResult: models.AttendeeSearchResult{
		Items: []models.Attendee{{ID: "attendee-2"}},
		Page:  models.PageInfo{NextCursor: "next-token"},
	}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees/search", map[string]any{"uuid": "target-uuid", "query": "ada"})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var got models.AttendeeSearchResult
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got.Items) != 1 || got.Items[0].ID != "attendee-2" {
		t.Errorf("Items = %+v, want the single attendee-2", got.Items)
	}
	if got.Page.NextCursor != "next-token" {
		t.Errorf("Page.NextCursor = %q, want %q", got.Page.NextCursor, "next-token")
	}
}

func TestAttendeeHandler_Search_InvalidCursorIsBadRequest(t *testing.T) {
	repo := &fakeAttendeeRepo{searchErr: repository.ErrInvalidCursor}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees/search", map[string]any{"cursor": "!!!not-base64!!!"})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
}

func TestAttendeeHandler_Search_NegativeLimitIsBadRequest(t *testing.T) {
	h := NewAttendeeHandler(&fakeAttendeeRepo{})
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees/search", map[string]any{"limit": -5})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestAttendeeHandler_Search_RepoErrorMapsTo500(t *testing.T) {
	repo := &fakeAttendeeRepo{searchErr: errBoom}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees/search", map[string]any{})
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

// --- 2026-09-04 audit: A1 (PATCH /attendees?email= hijack), A4 (empty POST) ---

func TestAttendeeHandler_Patch_IgnoresEmailQueryAndPatchesCaller(t *testing.T) {
	// A1: `?email=` used to select the row to patch *and* to return, with no
	// comparison against the JWT. The parameter is gone; the caller's own row
	// is the only row this route can reach.
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{
		testUser.Email:       {ID: "attendee-1", Email: testUser.Email},
		"victim@example.com": {ID: "attendee-2", Email: "victim@example.com"},
	}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	title := "New Title"
	w := doRequest(r, http.MethodPatch, "/attendees?email=victim@example.com", models.AttendeePatch{Title: &title})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if repo.patchedWith.email != testUser.Email {
		t.Errorf("PatchByEmail called with email = %q, want %q (the JWT email, never the query string)", repo.patchedWith.email, testUser.Email)
	}

	var got models.Attendee
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.Email != testUser.Email {
		t.Errorf("response Email = %q, want %q (never another attendee's decrypted row)", got.Email, testUser.Email)
	}
}

func TestAttendeeHandler_Patch_NotFoundWhenCallerHasNoRow(t *testing.T) {
	repo := &fakeAttendeeRepo{byEmail: map[string]models.Attendee{}}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPatch, "/attendees", models.AttendeePatch{})
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusNotFound, w.Body.String())
	}
}

func TestAttendeeHandler_Create_EmptyBodyIsBadRequest(t *testing.T) {
	// A4: `{}` used to 201 and write email='' against the caller's unique
	// idp_uuid, permanently wedging that account.
	repo := &fakeAttendeeRepo{}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees", map[string]any{})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
	if repo.insertCalls != 0 {
		t.Errorf("Insert called %d times, want 0", repo.insertCalls)
	}
}

func TestAttendeeHandler_Create_ConflictWhenEmailOwnedByAnother(t *testing.T) {
	// The scoped upsert no-ops rather than hijacking; 201 would claim a write
	// that never happened.
	repo := &fakeAttendeeRepo{insertErr: repository.ErrEmailOwnedByAnother}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/attendees", models.AttendeeInsert{FirstName: "Ada", LastName: "Lovelace"})
	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusConflict, w.Body.String())
	}
}

func TestAttendeeHandler_Create_EmptyCallerEmailIsRejected(t *testing.T) {
	// email is the conflict key; a token with no email claim would write ''.
	repo := &fakeAttendeeRepo{}
	h := NewAttendeeHandler(repo)
	r := newAttendeeTestRouter(h, &middleware.UserInfo{UserID: "user-1"})

	w := doRequest(r, http.MethodPost, "/attendees", models.AttendeeInsert{FirstName: "Ada", LastName: "Lovelace"})
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusUnauthorized, w.Body.String())
	}
	if repo.insertCalls != 0 {
		t.Errorf("Insert called %d times, want 0", repo.insertCalls)
	}
}
