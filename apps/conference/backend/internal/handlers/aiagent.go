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
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

// AIAgentClient is satisfied by *clients/aiagent.Client. All six AI feature
// routes live on one AIAgentHandler -- they're one cohesive feature surface
// backed by a single external client package, not six unrelated ones (see
// .claude/PLAN.md).
type AIAgentClient interface {
	RetrieveMatches(ctx context.Context, jwtAssertion string) ([]models.RecommendedUser, error)
	RetrieveO2BarRecommendations(ctx context.Context, jwtAssertion string, question *string) ([]models.O2BarRecommendationResponse, error)
	SendProfileInfo(ctx context.Context, jwtAssertion string, profile models.PersonalizeAgentUserProfile) (*http.Response, error)
	RetrieveAgendaRecommendations(ctx context.Context, jwtAssertion string) ([]models.PickedForYouSession, error)
	RetrieveChatResponse(ctx context.Context, jwtAssertion string, req models.ChatRequest) (*models.ChatResponse, error)
}

// AIAgentHandler exposes the AI feature HTTP endpoints.
type AIAgentHandler struct {
	client        AIAgentClient
	attendees     AttendeeProfileReader
	featureStatus config.AIFeatureStatus
}

// NewAIAgentHandler constructs an AIAgentHandler. attendees resolves
// uuid/profileUrl enrichment for the matches/O2Bar routes (see
// .claude/PLAN.md); featureStatus is echoed as-is by MaintenanceStatus.
func NewAIAgentHandler(client AIAgentClient, attendees AttendeeProfileReader, featureStatus config.AIFeatureStatus) *AIAgentHandler {
	return &AIAgentHandler{client: client, attendees: attendees, featureStatus: featureStatus}
}

// MaintenanceStatus handles GET /ai-maintenance-status. Unlike every other
// AI route, this is a pure static config echo: no context param, no client
// call, no error path at all -- matches the old code exactly.
func (h *AIAgentHandler) MaintenanceStatus(c *gin.Context) {
	c.JSON(http.StatusOK, models.AIFeatureStatus{
		EnabledChatAssistant:      h.featureStatus.EnabledChatAssistant,
		EnabledPersonalizedAgenda: h.featureStatus.EnabledPersonalizedAgenda,
		EnabledMatchMaker:         h.featureStatus.EnabledMatchMaker,
		EnabledO2Bar:              h.featureStatus.EnabledO2Bar,
	})
}
