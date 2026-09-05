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
}

// NewConnectionHandler constructs a ConnectionHandler. attendees is used to
// enrich a written connection with the *other* party's profile, so that a
// POST response carries the same fields the GET listing does -- omitting them
// made the two report different shapes for the same connection.
func NewConnectionHandler(connections ConnectionReader, attendees AttendeeProfileReader) *ConnectionHandler {
	return &ConnectionHandler{connections: connections, attendees: attendees}
}

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
	info.Email = attendee.Email
	info.ProfileURL = attendee.ProfileURL
	info.Title = attendee.Title
	info.Company = attendee.Company
	info.Country = attendee.Country
	return info
}
