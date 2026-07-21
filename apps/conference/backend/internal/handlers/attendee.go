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

// defaultProfileImageURL matches the old request_interceptor.bal: profileUrl
// was never derived from the JWT, it's a hardcoded literal for every user.
const defaultProfileImageURL = "https://wso2.cachefly.net/wso2/sites/all/2024/wso2con/avatar.png"

// AttendeeProfileReader is satisfied by *repository.AttendeeProfileRepo.
// GetByUUID is here for ConnectionHandler's sake (looking up the other
// party in a connection), not used by AttendeeHandler itself.
type AttendeeProfileReader interface {
	Insert(ctx context.Context, payload models.AttendeeInsert, idpUUID string) error
	GetByEmail(ctx context.Context, email string) (models.Attendee, error)
	GetByUUID(ctx context.Context, idpUUID string) (models.Attendee, error)
	PatchByEmail(ctx context.Context, email string, patch models.AttendeePatch, updatedBy string) error
	Search(ctx context.Context, filter models.AttendeeSearchFilter, excludedUUID string) (models.AttendeeSearchResult, error)
}

// AttendeeHandler exposes the attendee profile HTTP endpoints.
type AttendeeHandler struct {
	repo AttendeeProfileReader
}

// NewAttendeeHandler constructs an AttendeeHandler.
func NewAttendeeHandler(repo AttendeeProfileReader) *AttendeeHandler {
	return &AttendeeHandler{repo: repo}
}

// Create handles POST /attendees. idp_uuid always comes from the caller's
// JWT sub, never from the request body -- unlike the old code, which
// trusted payload.uuid outright (see .claude/PLAN.md).
func (h *AttendeeHandler) Create(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var payload models.AttendeeInsert
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	if err := h.repo.Insert(c.Request.Context(), payload, user.UserID); err != nil {
		slog.ErrorContext(c.Request.Context(), "inserting attendee failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.Status(http.StatusCreated)
}

// Patch handles PATCH /attendees?email=. 404s if no attendee exists for
// email, matching the old getAttendeeByEmail pre-check.
func (h *AttendeeHandler) Patch(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	email := c.Query("email")
	if email == "" {
		c.JSON(http.StatusBadRequest, gin.H{"message": "email is required"})
		return
	}

	var patch models.AttendeePatch
	if err := c.ShouldBindJSON(&patch); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	if _, err := h.repo.GetByEmail(c.Request.Context(), email); err != nil {
		h.respondAttendeeError(c, "fetching attendee failed", err)
		return
	}

	if err := h.repo.PatchByEmail(c.Request.Context(), email, patch, user.UserID); err != nil {
		h.respondAttendeeError(c, "patching attendee failed", err)
		return
	}

	updated, err := h.repo.GetByEmail(c.Request.Context(), email)
	if err != nil {
		h.respondAttendeeError(c, "fetching patched attendee failed", err)
		return
	}
	c.JSON(http.StatusOK, updated)
}

// Me handles GET /attendees/me, looking the caller up by their JWT email.
func (h *AttendeeHandler) Me(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	attendee, err := h.repo.GetByEmail(c.Request.Context(), user.Email)
	if err != nil {
		h.respondAttendeeError(c, "fetching attendee failed", err)
		return
	}
	c.JSON(http.StatusOK, attendee)
}

// Profile handles GET /user-profile. 404s whenever no attendee row exists
// for the caller's email -- see .claude/PLAN.md for why this isn't a
// fallback-to-JWT-only response.
func (h *AttendeeHandler) Profile(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	attendee, err := h.repo.GetByEmail(c.Request.Context(), user.Email)
	if err != nil {
		h.respondAttendeeError(c, "fetching attendee for profile failed", err)
		return
	}

	username := strings.TrimSpace(user.GivenName + " " + user.FamilyName)
	c.JSON(http.StatusOK, models.Profile{
		Username:  username,
		Email:     user.Email,
		ImageURL:  defaultProfileImageURL,
		QRUri:     attendee.QRUri,
		IsPartner: attendee.IsPartner,
	})
}

// Search handles POST /attendees/search, excluding the caller's own uuid.
func (h *AttendeeHandler) Search(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var filter models.AttendeeSearchFilter
	var body struct {
		UUID         *string `json:"uuid"`
		StartIndex   int     `json:"startIndex"`
		ItemsPerPage int     `json:"itemsPerPage"`
	}
	body.StartIndex = 1
	body.ItemsPerPage = 1000
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}
	if body.UUID != nil {
		filter.UUID = *body.UUID
	}
	filter.StartIndex = body.StartIndex
	filter.ItemsPerPage = body.ItemsPerPage

	result, err := h.repo.Search(c.Request.Context(), filter, user.UserID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "searching attendees failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *AttendeeHandler) respondAttendeeError(c *gin.Context, logMsg string, err error) {
	if errors.Is(err, repository.ErrNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"message": "attendee not found"})
		return
	}
	slog.ErrorContext(c.Request.Context(), logMsg, "error", err)
	c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
}
