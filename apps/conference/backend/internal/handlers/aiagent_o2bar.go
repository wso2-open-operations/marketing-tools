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

// O2BarRecommendationsGet handles GET /o2bar/recommendations. Sends no
// question to the external service, responds 200.
func (h *AIAgentHandler) O2BarRecommendationsGet(c *gin.Context) {
	h.o2barRecommendations(c, nil, http.StatusOK)
}

// O2BarRecommendationsPost handles POST /o2bar/recommendations. Forwards the
// caller's question (if any), responds 201 -- matches the old GET-is-200/
// POST-is-201 split exactly (see .claude/PLAN.md).
func (h *AIAgentHandler) O2BarRecommendationsPost(c *gin.Context) {
	var payload models.O2BarRecommendationInput
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}
	h.o2barRecommendations(c, payload.Question, http.StatusCreated)
}

// o2barRecommendations is the shared body for both O2Bar routes (same
// "two routes, one shared body" precedent as EventHandler.Agendas/
// LegacyAgendas). Enrichment follows the same not-found-vs-error split as
// Matches, but profileUrl prefers the AI response's own value first, only
// falling back to the DB attendee's profileUrl if the AI response didn't
// include one -- a different merge rule from matches, not a copy-paste of
// it (see .claude/PLAN.md).
func (h *AIAgentHandler) o2barRecommendations(c *gin.Context, question *string, successStatus int) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	raw, err := h.client.RetrieveO2BarRecommendations(c.Request.Context(), user.RawToken, question)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "retrieving O2Bar recommendations failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	recommendations := make([]models.O2BarRecommendation, 0, len(raw))
	for _, rec := range raw {
		var uuid string
		var profileURL *string

		attendee, err := h.attendees.GetByEmail(c.Request.Context(), rec.Email)
		switch {
		case err == nil:
			uuid = attendee.IDPUUID
			if attendee.ProfileURL != "" {
				profileURL = &attendee.ProfileURL
			}
		case errors.Is(err, repository.ErrNotFound):
			// No enrichment available -- uuid stays empty, profileUrl still
			// falls through to the AI response's own value below.
		default:
			slog.ErrorContext(c.Request.Context(), "looking up attendee for O2Bar recommendation failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
			return
		}

		if rec.ProfileURL != nil {
			profileURL = rec.ProfileURL
		}

		recommendations = append(recommendations, models.O2BarRecommendation{
			UUID:                 uuid,
			Name:                 rec.Name,
			Email:                rec.Email,
			ProfileURL:           profileURL,
			Reason:               rec.Reason,
			RecommendedQuestions: rec.RecommendedQuestions,
			AvailableTimeSlots:   rec.AvailableTimeSlots,
		})
	}

	c.JSON(successStatus, recommendations)
}
