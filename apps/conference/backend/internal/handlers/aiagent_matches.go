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
	"errors"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// Matches handles GET /users/me/matches. For every recommended user, looks
// up the attendee by email to resolve uuid/profileUrl -- "not found" is not
// an error and just leaves those fields empty, but any other lookup error
// aborts the whole request (partial results are discarded), matching the
// old ConAttendee? optional-nil path exactly (see .claude/PLAN.md).
func (h *AIAgentHandler) Matches(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	recommended, err := h.client.RetrieveMatches(c.Request.Context(), user.RawToken)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "retrieving matches failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	matches := make([]models.MatchedUser, 0, len(recommended))
	for _, ru := range recommended {
		var uuid string
		var profileURL *string

		attendee, err := h.attendees.GetByEmail(c.Request.Context(), ru.Email)
		switch {
		case err == nil:
			uuid = attendee.IDPUUID
			if attendee.ProfileURL != "" {
				profileURL = &attendee.ProfileURL
			}
		case errors.Is(err, repository.ErrNotFound):
			// No enrichment available -- uuid/profileUrl stay empty.
		default:
			slog.ErrorContext(c.Request.Context(), "looking up attendee for match failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
			return
		}

		matches = append(matches, models.MatchedUser{
			UUID:       uuid,
			Name:       ru.Name,
			Company:    ru.Company,
			Title:      ru.Title,
			Reason:     ru.Reason,
			Tags:       ru.Tags,
			ProfileURL: profileURL,
		})
	}

	c.JSON(http.StatusOK, matches)
}
