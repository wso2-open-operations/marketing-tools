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
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// ConnectionReader is satisfied by *repository.ConnectionRepo.
//
// One method per transition, mirroring the routes. The old interface had a
// single Upsert taking a caller-supplied status, which is what let the
// requester walk their own request to accepted: the transition was a value in
// a payload rather than a property of the endpoint. Each method here decides
// for itself who is allowed to call it, and none of them accepts a state.
type ConnectionReader interface {
	Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error)
	Request(ctx context.Context, requesterUUID, addresseeUUID string) (models.Connection, error)
	Accept(ctx context.Context, connectionID, callerUUID string) (models.Connection, error)
	Delete(ctx context.Context, connectionID, callerUUID string) error
}

// ConnectionHandler exposes the network connections HTTP endpoints.
type ConnectionHandler struct {
	connections ConnectionReader
	attendees   AttendeeProfileReader
	notifier    NotificationSender
	notifyTitle string
}

// NewConnectionHandler constructs a ConnectionHandler. attendees is used to
// enrich a written connection with the *other* party's profile, so that a
// POST response carries the same fields the GET listing does -- omitting them
// made the two report different shapes for the same connection.
//
// notifier pushes the request/accept notification to the other party. A nil
// notifier disables those pushes and leaves every route otherwise intact,
// which is what a deployment with no NOTIFICATION_* configuration gets --
// silence rather than a nil dereference on every connection write.
//
// notifyTitle is the one title every push from this service carries; blank
// falls back to DefaultNotificationTitle. It does not describe the event --
// the body does -- so it is the same string for a request as for an accept,
// and the handler holds one rather than one per transition.
func NewConnectionHandler(
	connections ConnectionReader,
	attendees AttendeeProfileReader,
	notifier NotificationSender,
	notifyTitle string,
) *ConnectionHandler {
	if strings.TrimSpace(notifyTitle) == "" {
		// An unset environment variable arrives as "", and a push with an
		// empty title renders as a blank header on the device rather than as
		// an error anyone would notice.
		notifyTitle = DefaultNotificationTitle
	}
	return &ConnectionHandler{
		connections: connections,
		attendees:   attendees,
		notifier:    notifier,
		notifyTitle: notifyTitle,
	}
}

const (
	// DefaultNotificationTitle heads the connection pushes when no title is
	// configured. It names the conference rather than the event, so that what
	// lands on an attendee's lock screen reads as coming from the app.
	//
	// The admin broadcast is not covered by it: that endpoint takes its title
	// from the request body, because an admin writing a one-off announcement
	// is choosing the whole message.
	DefaultNotificationTitle = "WSO2Con"

	// The bodies carry the meaning, since the title is common to every push.
	// They are not configurable: keeping them free of attendee data is a
	// property of the feature rather than a preference. A push is delivered
	// by an external service and rendered on a lock screen, so anything put
	// in one is readable by whoever is holding the phone and is retained in a
	// system the conference does not control -- naming the other party would
	// leak who is connecting with whom to a shoulder-surfer, for a
	// notification whose whole job is to get the attendee to open the app,
	// where the name is already waiting.
	connectionRequestBody = "Someone would like to connect with you. Open WSO2Con to see who."
	connectionAcceptBody  = "Someone accepted your connection request. Open WSO2Con to see who."

	// connectionNotifyTimeout bounds the detached send. The notification
	// client has its own 10s request timeout; this is the outer bound on the
	// goroutine that wraps it.
	connectionNotifyTimeout = 30 * time.Second
)

// Get handles GET /users/me/connections.
func (h *ConnectionHandler) Get(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	info, err := h.connections.Get(c.Request.Context(), user.UserID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching connections failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.JSON(http.StatusOK, info)
}

// Create handles POST /users/me/connections. The body carries targetId and
// nothing else: the requester is the JWT sub, and there is no field through
// which a caller can name a state, so this route can only ever produce a
// pending connection. Any other field in the payload is ignored.
//
// Validating the target and writing the row is the repository's job, done in
// one transaction -- the old handler checked the target with a separate read
// and wrote afterwards, which left an orphan row whenever the write raced or
// the 404 came late.
func (h *ConnectionHandler) Create(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.ConnectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		// Covers both a body that isn't JSON and one that omits targetId:
		// ConnectionRequest marks the field binding:"required".
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body: targetId is required"})
		return
	}
	// binding:"required" only rejects the empty string, so a whitespace-only
	// id would otherwise reach the repository and be looked up verbatim.
	if strings.TrimSpace(req.TargetID) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body: targetId is required"})
		return
	}

	conn, err := h.connections.Request(c.Request.Context(), user.UserID, req.TargetID)
	if err != nil {
		switch {
		case errors.Is(err, repository.ErrSelfConnection):
			c.JSON(http.StatusBadRequest, gin.H{"message": "cannot connect to yourself"})
		case errors.Is(err, repository.ErrNotFound):
			c.JSON(http.StatusNotFound, gin.H{"message": "attendee not found"})
		default:
			slog.ErrorContext(c.Request.Context(), "requesting connection failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		}
		return
	}

	h.notifyConnection(conn, user.UserID, connectionRequestBody)

	c.JSON(http.StatusCreated, h.describeOtherParty(c.Request.Context(), conn, user.UserID))
}

// Accept handles POST /users/me/connections/:id/accept. Only the addressee may
// accept, and that is enforced by the repository's UPDATE predicate rather
// than by a read-then-write here: a caller who is not the addressee gets
// ErrConnectionForbidden, and one who is not a party at all gets ErrNotFound,
// so a stranger cannot probe for the existence of an id.
func (h *ConnectionHandler) Accept(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	id := c.Param("id")
	if !uuidPattern.MatchString(id) {
		c.JSON(http.StatusBadRequest, gin.H{"message": "id must be a valid UUID"})
		return
	}

	conn, err := h.connections.Accept(c.Request.Context(), id, user.UserID)
	if err != nil {
		writeConnectionTransitionError(c, "accepting connection failed", err)
		return
	}

	h.notifyConnection(conn, user.UserID, connectionAcceptBody)

	c.JSON(http.StatusOK, h.describeOtherParty(c.Request.Context(), conn, user.UserID))
}

// Delete handles DELETE /users/me/connections/:id. One route covers declining,
// withdrawing and unfriending: the redesign stores no "declined" state, so
// either party removing the row simply returns the pair to having no
// relationship. It answers 204 with no body -- there is nothing left to
// describe.
func (h *ConnectionHandler) Delete(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	id := c.Param("id")
	if !uuidPattern.MatchString(id) {
		c.JSON(http.StatusBadRequest, gin.H{"message": "id must be a valid UUID"})
		return
	}

	if err := h.connections.Delete(c.Request.Context(), id, user.UserID); err != nil {
		writeConnectionTransitionError(c, "deleting connection failed", err)
		return
	}
	c.Status(http.StatusNoContent)
}

// notifyConnection pushes the transition to whichever party did not cause it.
//
// Delete deliberately sends nothing: one route covers declining, withdrawing
// and unfriending, so a push there would tell the other party they had been
// turned down or removed -- three different pieces of bad news the redesign
// keeps private by storing no declined state in the first place.
//
// The send is fire-and-forget on its own goroutine, for the same reason
// describeOtherParty swallows its lookup error: the row is already committed,
// so the notification service may not turn a successful transition into a 500
// the client would retry. It carries its own context because the request's is
// cancelled the moment the handler returns.
//
// Only the recipient uuid varies per call -- the title is common to every
// push and the body is a fixed string, so no profile is read here and nothing
// about either party travels to the notification service beyond the two uuids
// it routes on.
func (h *ConnectionHandler) notifyConnection(conn models.Connection, actorUUID, body string) {
	if h.notifier == nil {
		return
	}

	recipient, ok := conn.Other(actorUUID)
	if !ok {
		// Unreachable through these routes, and already logged as an error by
		// describeOtherParty; guarded here so a row the actor is not party to
		// cannot address a push at an arbitrary attendee.
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), connectionNotifyTimeout)
		defer cancel()

		if err := h.notifier.SendAttendeeNotification(
			ctx, actorUUID, []string{recipient}, h.notifyTitle, body,
		); err != nil {
			slog.ErrorContext(ctx, "sending connection notification failed",
				"error", err, "connectionId", conn.ID)
			return
		}
		slog.InfoContext(ctx, "connection notification sent",
			"connectionId", conn.ID, "actor", actorUUID)
	}()
}

// writeConnectionTransitionError maps the errors the id-addressed transitions
// share onto responses. Accept and Delete both act on an existing row on
// behalf of one of its two parties, so they fail in the same four ways and
// answering them differently would only invite the two routes to drift.
func writeConnectionTransitionError(c *gin.Context, logMsg string, err error) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		c.JSON(http.StatusNotFound, gin.H{"message": "connection not found"})
	case errors.Is(err, repository.ErrConnectionForbidden):
		c.JSON(http.StatusForbidden, gin.H{"message": "only the addressee may accept this request"})
	case errors.Is(err, repository.ErrConnectionNotPending):
		c.JSON(http.StatusConflict, gin.H{"message": "connection is no longer pending"})
	default:
		slog.ErrorContext(c.Request.Context(), logMsg, "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
	}
}

// describeOtherParty renders a written connection as the client sees it: the
// row's id and state, plus the profile of whoever the caller is not.
//
// The profile lookup happens after the write has already committed, so it
// cannot be allowed to turn a successful transition into a 500 -- the client
// would retry an accept that had in fact succeeded, and be told 409. A failed
// or missing profile therefore degrades to the ids and status the handler
// already knows, which is enough for the client to address the row, and the
// lookup failure is logged for us rather than surfaced to them.
func (h *ConnectionHandler) describeOtherParty(ctx context.Context, conn models.Connection, callerUUID string) models.ConnectionUserInfo {
	info := models.ConnectionUserInfo{
		ConnectionID: conn.ID,
		Status:       conn.State.String(),
	}

	other, ok := conn.Other(callerUUID)
	if !ok {
		// Unreachable through these routes -- every transition is authorized
		// against the caller -- but a row the caller is not party to must not
		// be described with a party's identity.
		slog.ErrorContext(ctx, "connection does not involve the caller", "connectionId", conn.ID)
		return info
	}
	info.UserID = other

	attendee, err := h.attendees.GetByUUID(ctx, other)
	if err != nil {
		slog.ErrorContext(ctx, "enriching connection with attendee profile failed",
			"error", err, "connectionId", conn.ID)
		return info
	}

	info.Name = strings.TrimSpace(attendee.FirstName + " " + attendee.LastName)
	// Same gate the GET buckets apply: the address is released only once the
	// pair is connected. Create returns a pending connection, so it must not
	// hand back the target's email -- that would give away on the request what
	// accepting is supposed to exchange, and would do it without the target
	// having done anything.
	if conn.State == models.ConnectionAccepted {
		info.Email = attendee.Email
	}
	info.ProfileURL = attendee.ProfileURL
	info.Title = attendee.Title
	info.Company = attendee.Company
	info.Country = attendee.Country
	return info
}
