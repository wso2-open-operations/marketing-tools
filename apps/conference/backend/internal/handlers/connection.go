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
type ConnectionReader interface {
	Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error)
	Upsert(ctx context.Context, initiatorUUID, recipientUUID string, status models.ConnectionStatus) error
}

// ConnectionHandler exposes the network connections HTTP endpoints.
type ConnectionHandler struct {
	connections ConnectionReader
	attendees   AttendeeProfileReader
}

// NewConnectionHandler constructs a ConnectionHandler. attendees is used to
// look up the target user's profile after a successful upsert, to build the
// response -- same repo dependency as the old code's post-upsert
// getAttendees call.
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

// Create handles POST /users/me/connections. After upserting, looks up the
// target's attendee row to build the response; 404s if the target has no
// attendee row, matching the old attendeesResponse.totalResults == 0 check.
// The old code's best-effort push notification on request/accept is
// dropped entirely -- no notification module exists to call (see
// .claude/PLAN.md).
func (h *ConnectionHandler) Create(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.UserConnectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	if !req.Status.IsValid() {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid connection status"})
		return
	}

	if err := h.connections.Upsert(c.Request.Context(), user.UserID, req.UserID, req.Status); err != nil {
		slog.ErrorContext(c.Request.Context(), "upserting connection failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	target, err := h.attendees.GetByUUID(c.Request.Context(), req.UserID)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"message": "attendee not found"})
			return
		}
		slog.ErrorContext(c.Request.Context(), "fetching target attendee failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	c.JSON(http.StatusCreated, models.ConnectionUserInfo{
		UserID: req.UserID,
		Name:   strings.TrimSpace(target.FirstName + " " + target.LastName),
		Email:  target.Email,
	})
}
