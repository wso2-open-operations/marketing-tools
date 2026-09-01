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
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/repository"
)

type LeaderboardHandler struct {
	repo   repository.LeaderboardReader
	events repository.EventReader
}

func NewLeaderboardHandler(repo repository.LeaderboardReader, events repository.EventReader) *LeaderboardHandler {
	return &LeaderboardHandler{repo: repo, events: events}
}

func (h *LeaderboardHandler) GetLeaderboard(c *gin.Context) {
	limitStr := c.Query("limit")
	limit := 10
	if limitStr != "" {
		parsed, err := strconv.Atoi(limitStr)
		if err != nil || parsed <= 0 {
			c.JSON(http.StatusBadRequest, gin.H{"message": "invalid limit parameter"})
			return
		}
		limit = parsed
	}

	currentEvent, err := h.events.GetCurrentEvent(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to get current event", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	entries, err := h.repo.GetLeaderboard(c.Request.Context(), limit, currentEvent.ID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to get leaderboard", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	user := middleware.UserInfoFromContext(c.Request.Context())
	currentUserID := ""
	if user != nil {
		currentUserID = user.UserID
	}

	for i := range entries {
		if entries[i].UserID != currentUserID {
			hash := sha256.Sum256([]byte(entries[i].UserID))
			entries[i].UserID = hex.EncodeToString(hash[:])[:16]
		}
	}

	c.JSON(http.StatusOK, entries)
}

func (h *LeaderboardHandler) GetPreferences(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	showFullName, err := h.repo.GetPreferences(c.Request.Context(), user.UserID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to get leaderboard preferences", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"showFullName": showFullName})
}

func (h *LeaderboardHandler) UpdatePreferences(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req struct {
		ShowFullName *bool `json:"showFullName" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request payload"})
		return
	}

	if err := h.repo.UpdatePreferences(c.Request.Context(), user.UserID, *req.ShowFullName); err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to update leaderboard preferences", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	c.JSON(http.StatusOK, req)
}
