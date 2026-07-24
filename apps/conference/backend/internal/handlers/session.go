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

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// SessionReader reads session data. Satisfied by *repository.SessionRepo.
type SessionReader interface {
	GetSession(ctx context.Context, id string) (models.Session, error)
	GetCurrentSessions(ctx context.Context) ([]models.Session, error)
}

// SessionHandler exposes the public, unauthenticated session HTTP endpoints
// (conference agenda data — not gated by x-jwt-assertion, matching the old
// Ballerina service where these routes never touch the JWT or resource
// context at all).
type SessionHandler struct {
	reader SessionReader
}

// NewSessionHandler constructs a SessionHandler.
func NewSessionHandler(reader SessionReader) *SessionHandler {
	return &SessionHandler{reader: reader}
}

// Get handles GET /sessions/:id.
func (h *SessionHandler) Get(c *gin.Context) {
	session, err := h.reader.GetSession(c.Request.Context(), c.Param("id"))
	switch {
	case err == nil:
		c.JSON(http.StatusOK, session)
	case errors.Is(err, repository.ErrNotFound):
		c.Status(http.StatusNotFound)
	default:
		slog.ErrorContext(c.Request.Context(), "fetching session failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
	}
}

// Current handles GET /sessions/current. It returns every session in the
// current conference as Session objects (the same shape as the agenda
// endpoints), ordered by start time.
func (h *SessionHandler) Current(c *gin.Context) {
	sessions, err := h.reader.GetCurrentSessions(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching current sessions failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if sessions == nil {
		sessions = []models.Session{}
	}
	c.JSON(http.StatusOK, sessions)
}
