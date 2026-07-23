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
// picked-for-you service returns fully-formed session objects itself, so no
// DB enrichment happens here at all (see .claude/PLAN.md).
func (h *AIAgentHandler) AgendaRecommendations(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	sessions, err := h.client.RetrieveAgendaRecommendations(c.Request.Context(), user.RawToken)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "retrieving agenda recommendations failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if sessions == nil {
		sessions = []models.PickedForYouSession{}
	}
	c.JSON(http.StatusOK, sessions)
}
