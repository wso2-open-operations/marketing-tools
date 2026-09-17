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
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// NotificationRecipientReader is satisfied by *repository.AttendeeProfileRepo.
type NotificationRecipientReader interface {
	ListAllUUIDs(ctx context.Context) ([]string, error)
}

// NotificationSender is satisfied by *notification.Client.
type NotificationSender interface {
	SendAttendeeNotification(ctx context.Context, senderUUID string, recipients []string, title, body string) error
}

// NotificationHandler exposes the admin broadcast-push endpoint.
type NotificationHandler struct {
	recipients NotificationRecipientReader
	sender     NotificationSender
	adminRoles []string
}

// NewNotificationHandler constructs a NotificationHandler. adminRoles is the
// allow-list of JWT groups/roles permitted to broadcast
// (config.Config.NotificationAdminRoles, from NOTIFICATION_ADMIN_ROLES);
// leaving it empty locks the endpoint down rather than opening it up.
//
// That list is deliberately not RBAC_ADMIN_ROLES. See
// config.Config.NotificationAdminRoles for why a conference-wide push is a
// narrower entitlement than general event administration.
func NewNotificationHandler(recipients NotificationRecipientReader, sender NotificationSender, adminRoles []string) *NotificationHandler {
	return &NotificationHandler{recipients: recipients, sender: sender, adminRoles: adminRoles}
}

// requireNotificationAdmin resolves the caller and enforces the broadcast
// allow-list. It returns the caller and true when the request may proceed;
// otherwise it has already written the 401/403 response and the handler must
// return.
//
// Shaped after AIAgentHandler.requireAIAdmin so that every admin-gated route in
// this package refuses a caller the same way: same status codes, same body, and
// a refusal logged with both the caller and the route. Only this one endpoint
// uses it today -- it is a named helper rather than four inline lines because
// the gate is the whole security boundary of the route, and a boundary that
// lives in a function is one a reader can find, test, and see reused.
func (h *NotificationHandler) requireNotificationAdmin(c *gin.Context) (*middleware.UserInfo, bool) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return nil, false
	}
	if !user.HasAnyGroup(h.adminRoles) {
		slog.WarnContext(c.Request.Context(),
			"non-admin attempted to broadcast a notification",
			"user", user.UserID, "path", c.FullPath())
		c.JSON(http.StatusForbidden, gin.H{"message": "forbidden"})
		return nil, false
	}
	return user, true
}

// auditBroadcast records a push that the notification service accepted: who
// sent it, and how many devices' worth of attendees it was addressed to.
//
// It mirrors auditAIAdminWrite, and exists for the same reason: nothing else
// writes the change down. The notification service answers 202 and keeps no
// caller-facing trail, delivery is asynchronous with no per-recipient status to
// fetch back, and requireNotificationAdmin only logs the calls it *refuses* --
// so a broadcast that actually went out to every attendee would otherwise leave
// no record of who sent it.
//
// The title is logged; the body is not. A broadcast title is operational
// metadata -- it is what an operator would search for when asked "who sent
// that?" -- while the body is free text an admin typed, can run to 1000 bytes,
// and adds nothing to the question this record answers. recipients is the
// attendee count the payload carried, not a delivery count: the fan-out to
// devices and the successes among them happen downstream, where this backend
// can see neither.
func auditBroadcast(c *gin.Context, user *middleware.UserInfo, title string, recipients int) {
	slog.InfoContext(c.Request.Context(), "notification admin action: "+auditBroadcastNotification,
		"user", user.UserID, "action", auditBroadcastNotification,
		"title", title, "recipients", recipients)
}

// The action named in the audit trail above. A stable token rather than prose,
// for the same reason as the aiagent_admin.go audit actions: it lands in the
// log message as well as in an attribute, and a message that is grep-able
// across deployments is worth more than one that reads nicely once.
const auditBroadcastNotification = "broadcast-notification"

// Create handles POST /users/notifications: a broadcast push to every
// attendee, restricted to callers holding one of the NOTIFICATION_ADMIN_ROLES.
//
// The frontend hides its trigger UI behind its own role check, but that is
// cosmetic -- requireNotificationAdmin is the real gate, and it is the reason
// the endpoint reads the JWT groups/roles claims at all. The two are configured
// independently today, so a client that shows the button to somebody this list
// does not name will get a 403 rather than a send; that is the correct way
// round for the pair to disagree.
//
// Delivery is delegated wholesale to the external notification service, so
// there is no per-recipient status to report and the response carries no body;
// the client treats any 2xx as sent.
func (h *NotificationHandler) Create(c *gin.Context) {
	user, ok := h.requireNotificationAdmin(c)
	if !ok {
		return
	}

	var req models.UserNotificationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}
	if problem := req.Validate(); problem != "" {
		c.JSON(http.StatusBadRequest, gin.H{"message": problem})
		return
	}

	recipients, err := h.recipients.ListAllUUIDs(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "listing notification recipients failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	if err := h.sender.SendAttendeeNotification(
		c.Request.Context(), user.UserID, recipients, req.Title, req.Description,
	); err != nil {
		slog.ErrorContext(c.Request.Context(), "sending broadcast notification failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	auditBroadcast(c, user, req.Title, len(recipients))
	c.Status(http.StatusOK)
}
