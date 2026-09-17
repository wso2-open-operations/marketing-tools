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
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
)

type fakeNotificationRecipients struct {
	uuids []string
	err   error
}

func (f *fakeNotificationRecipients) ListAllUUIDs(ctx context.Context) ([]string, error) {
	return f.uuids, f.err
}

type fakeNotificationSender struct {
	err error

	called     bool
	senderUUID string
	recipients []string
	title      string
	body       string
}

func (f *fakeNotificationSender) SendAttendeeNotification(ctx context.Context, senderUUID string, recipients []string, title, body string) error {
	f.called = true
	f.senderUUID = senderUUID
	f.recipients = recipients
	f.title = title
	f.body = body
	return f.err
}

var notificationAdminRoles = []string{"app-con-registrant-admin"}

func newNotificationTestRouter(h *NotificationHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.POST("/users/notifications", h.Create)
	return r
}

func adminUser() *middleware.UserInfo {
	return &middleware.UserInfo{
		Email:  "admin@example.com",
		UserID: "admin-1",
		Groups: []string{"wso2-everyone", "app-con-registrant-admin"},
	}
}

func validNotificationBody() map[string]string {
	return map[string]string{"title": "Keynote", "description": "Starting in 10 minutes"}
}

func TestNotificationHandler_Create_Unauthenticated(t *testing.T) {
	h := NewNotificationHandler(&fakeNotificationRecipients{}, &fakeNotificationSender{}, notificationAdminRoles)
	r := newNotificationTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestNotificationHandler_Create_NonAdminIsForbidden(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{}, sender, notificationAdminRoles)
	// testUser carries no groups at all -- the common case for an attendee.
	r := newNotificationTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if sender.called {
		t.Error("sender was called for a non-admin caller")
	}
}

// An empty allow-list must deny rather than fall open, so a misconfigured
// deployment can't turn the broadcast into an any-attendee capability.
func TestNotificationHandler_Create_EmptyAdminRolesDeniesEveryone(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{}, sender, nil)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if sender.called {
		t.Error("sender was called with no admin roles configured")
	}
}

// The entitlement may arrive in `roles` rather than `groups` -- which claim an
// Asgardeo application stamps is its own attribute-mapping decision -- so the
// gate has to honour both. Checking only `groups` would 403 a legitimately
// entitled admin on a deployment whose app maps to `roles`, and the symptom
// (a correct role name that still gets refused) reads as a wrong allow-list
// rather than as a claim this code never looked at.
func TestNotificationHandler_Create_RoleClaimEntitlesLikeGroupClaim(t *testing.T) {
	recipients := &fakeNotificationRecipients{uuids: []string{"uuid-1"}}
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(recipients, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, &middleware.UserInfo{
		Email:  "admin@example.com",
		UserID: "admin-1",
		// Nothing in Groups; the entitlement is in Roles only.
		Roles: []string{"app-con-registrant-admin"},
	})

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if !sender.called {
		t.Error("sender was not called for an admin entitled via the roles claim")
	}
}

// The broadcast gates on NOTIFICATION_ADMIN_ROLES, not RBAC_ADMIN_ROLES. A
// general event admin who is not named on the broadcast list must be refused:
// a push reaches every attendee's device and cannot be recalled, so it is a
// narrower entitlement than the rest of event administration.
func TestNotificationHandler_Create_GeneralEventAdminIsForbidden(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{}, sender, []string{"app-push-notification-admin"})
	r := newNotificationTestRouter(h, &middleware.UserInfo{
		Email:  "eventadmin@example.com",
		UserID: "event-admin-1",
		// The RBAC_ADMIN_ROLES population, minus the broadcast role.
		Groups: []string{"event-admin-stg", "app-con-registrant-admin"},
	})

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if sender.called {
		t.Error("sender was called for a caller holding only general event-admin roles")
	}
}

func TestNotificationHandler_Create_BroadcastsToAllAttendees(t *testing.T) {
	recipients := &fakeNotificationRecipients{uuids: []string{"uuid-1", "uuid-2"}}
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(recipients, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if !sender.called {
		t.Fatal("sender was not called")
	}
	if sender.senderUUID != "admin-1" {
		t.Errorf("senderUUID = %q, want %q", sender.senderUUID, "admin-1")
	}
	if len(sender.recipients) != 2 {
		t.Errorf("recipients = %v, want 2 entries", sender.recipients)
	}
	if sender.title != "Keynote" || sender.body != "Starting in 10 minutes" {
		t.Errorf("title/body = %q/%q, want %q/%q",
			sender.title, sender.body, "Keynote", "Starting in 10 minutes")
	}
	if w.Body.Len() != 0 {
		t.Errorf("expected an empty body, got %q", w.Body.String())
	}
}

func TestNotificationHandler_Create_MissingTitleIsBadRequest(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{}, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	// Whitespace only: trimmed to empty, so this is a missing title.
	w := doRequest(r, http.MethodPost, "/users/notifications",
		map[string]string{"title": "   ", "description": "body"})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
	if sender.called {
		t.Error("sender was called for an invalid payload")
	}
}

func TestNotificationHandler_Create_OverlongTitleIsBadRequest(t *testing.T) {
	h := NewNotificationHandler(&fakeNotificationRecipients{}, &fakeNotificationSender{}, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications",
		map[string]string{"title": strings.Repeat("a", 201), "description": "body"})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

// The frontend caps the title at 50 chars, but the server limit stays at the
// old Ballerina 200 -- a client stricter than the server must never be the
// reason a valid request fails.
func TestNotificationHandler_Create_AcceptsTitleLongerThanFrontendCap(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{uuids: []string{"uuid-1"}}, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications",
		map[string]string{"title": strings.Repeat("a", 120), "description": "body"})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if !sender.called {
		t.Error("sender was not called")
	}
}

func TestNotificationHandler_Create_EmptyDescriptionIsAllowed(t *testing.T) {
	sender := &fakeNotificationSender{}
	h := NewNotificationHandler(&fakeNotificationRecipients{uuids: []string{"uuid-1"}}, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications",
		map[string]string{"title": "Title only"})
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	if sender.body != "" {
		t.Errorf("body = %q, want empty", sender.body)
	}
}

func TestNotificationHandler_Create_RecipientLookupErrorIs500(t *testing.T) {
	sender := &fakeNotificationSender{}
	recipients := &fakeNotificationRecipients{err: errors.New("db down")}
	h := NewNotificationHandler(recipients, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
	if sender.called {
		t.Error("sender was called despite the recipient lookup failing")
	}
}

func TestNotificationHandler_Create_SendErrorIs500(t *testing.T) {
	sender := &fakeNotificationSender{err: errors.New("upstream unavailable")}
	h := NewNotificationHandler(&fakeNotificationRecipients{uuids: []string{"uuid-1"}}, sender, notificationAdminRoles)
	r := newNotificationTestRouter(h, adminUser())

	w := doRequest(r, http.MethodPost, "/users/notifications", validNotificationBody())
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}
