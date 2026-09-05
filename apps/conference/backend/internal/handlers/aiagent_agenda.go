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
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// AgendaRecommendations handles GET /agenda/recommendations. The external
// picked-for-you service returns fully-formed session objects, which this
// backend then DAY-ASSOCIATES: each recommendation's session id is resolved
// against marketingops.sessions to attach the real conference_days id (Phase
// E), so the client stops intersecting recommendation ids against the loaded
// agenda to figure out each session's day (and stops silently dropping ones it
// can't place -- FE.md 3.7).
//
// This assumes the external service's PickedForYouSession.ID is a marketingops
// session uuid. That correspondence can't be verified until a real
// picked-for-you backend exists (none does in any environment yet), so
// enrichment is best-effort: an id that doesn't resolve just keeps an empty
// dayId, and if no sessionDays reader is wired the response passes through
// unchanged.
func (h *AIAgentHandler) AgendaRecommendations(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	// Personalized "Picked for You" is gated on the personalized-agenda flag
	// (shared with POST /users/profile). Disabled -> clean 503 rather than a raw
	// 500 from an unreachable backend (defense-in-depth alongside
	// AI_ENABLED_PERSONALIZED_AGENDA).
	if !h.featureStatus.EnabledPersonalizedAgenda {
		respondFeatureDisabled(c, "Personalized agenda")
		return
	}

	sessions, err := h.client.RetrieveAgendaRecommendations(c.Request.Context(), user.RawToken)
	if err != nil {
		respondAIUpstreamError(c, "retrieving agenda recommendations failed", err)
		return
	}
	if sessions == nil {
		sessions = []models.PickedForYouSession{}
	}

	if h.sessionDays != nil && len(sessions) > 0 {
		ids := make([]string, len(sessions))
		for i := range sessions {
			ids[i] = sessions[i].ID
		}
		dayBySession, err := h.sessionDays.DayIDsForSessions(c.Request.Context(), ids)
		if err != nil {
			// Enrichment is best-effort: log and return the un-enriched
			// recommendations rather than failing the whole request.
			slog.WarnContext(c.Request.Context(), "day-associating recommendations failed", "error", err)
		} else {
			for i := range sessions {
				if dayID, ok := dayBySession[sessions[i].ID]; ok {
					sessions[i].DayID = dayID
				}
			}
		}
	}

	c.JSON(http.StatusOK, sessions)
}
