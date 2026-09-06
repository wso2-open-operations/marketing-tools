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
	"fmt"
	"log/slog"
	"net/http"
	"net/url"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/clients/aiagent"
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

// SessionDayReader resolves session ids to their conference_days id, used to
// day-associate picked-for-you recommendations (Phase E). Satisfied by
// *repository.SessionRepo. Optional: when nil, recommendations pass through
// without day enrichment.
type SessionDayReader interface {
	DayIDsForSessions(ctx context.Context, sessionIDs []string) (map[string]string, error)
}

// AIAgentHandler exposes the AI feature HTTP endpoints.
type AIAgentHandler struct {
	client        AIAgentClient
	attendees     AttendeeProfileReader
	featureStatus config.AIFeatureStatus
	sessionDays   SessionDayReader
}

// NewAIAgentHandler constructs an AIAgentHandler. attendees resolves
// uuid/profileUrl enrichment for the matches/O2Bar routes (see
// .claude/PLAN.md); featureStatus is echoed as-is by MaintenanceStatus.
// sessionDays day-associates agenda recommendations (Phase E); pass nil to
// disable that enrichment (e.g. in tests that don't exercise it).
func NewAIAgentHandler(client AIAgentClient, attendees AttendeeProfileReader, featureStatus config.AIFeatureStatus, sessionDays SessionDayReader) *AIAgentHandler {
	return &AIAgentHandler{client: client, attendees: attendees, featureStatus: featureStatus, sessionDays: sessionDays}
}

// respondFeatureDisabled writes the standard response for an AI feature whose
// config flag is switched off. It answers 503 Service Unavailable (not 404 or
// 500) so the frontend treats the feature as temporarily off and retriable --
// not a client bug and not a server crash. This is the code-level companion to
// MaintenanceStatus: even when the status echo says a feature is enabled, each
// endpoint still refuses to call the external AI service unless its own flag is
// actually on, so a stale/mismatched status can never surface a raw 500 from an
// endpoint whose feature is meant to be off.
func respondFeatureDisabled(c *gin.Context, name string) {
	c.JSON(http.StatusServiceUnavailable, gin.H{"message": name + " is under maintenance"})
}

// aiServiceUnreachable reports whether err is a transport-level failure to
// reach the external AI service (connection refused, DNS failure, TLS error,
// request timeout) rather than an error *response* from a service that was
// reached. A reached-but-unhappy service yields an *aiagent.StatusError, while
// a failed http.Client.Do surfaces as a *url.Error, so a *url.Error anywhere in
// the chain means "couldn't reach it". Handlers map that to a retriable 503;
// every other failure (a bad status, a decode error, an internal bug) stays a
// 500.
//
// One case is deliberately excluded: a rejected OAuth2 token fetch also travels
// as a *url.Error, because the oauth2 transport fails the request before it is
// ever sent. Bad or unsubscribed credentials are a deployment error that will
// never fix itself, so calling them "temporarily unavailable" would be a lie
// that hides the one thing worth acting on.
func aiServiceUnreachable(err error) bool {
	if _, isTokenFailure := aiagent.TokenFetchStatusFrom(err); isTokenFailure {
		return false
	}
	var urlErr *url.Error
	return errors.As(err, &urlErr)
}

// respondAIUpstreamError logs err and writes the client-facing response for a
// failed call to the external AI service: a transport failure (service
// unreachable / timed out) degrades to a retriable 503, while any other error
// stays a 500. Used by every AI endpoint so an enabled-but-not-yet-plugged-in
// backend reports "temporarily unavailable" instead of "server bug".
func respondAIUpstreamError(c *gin.Context, logMsg string, err error) {
	// The upstream status goes in the message, not only in an attribute. The
	// deployed log viewer renders slog's message and drops its attributes, so a
	// gateway 401 previously read as a bare "retrieving chat response failed"
	// with the one useful fact invisible.
	const credentialHint = " -- check this service's AI gateway credentials (AI_TOKEN_URL/AI_CLIENT_ID/AI_CLIENT_SECRET), not the caller's JWT"
	switch status, ok := aiagent.StatusCodeFrom(err); {
	case ok:
		logMsg = fmt.Sprintf("%s: AI service returned HTTP %d", logMsg, status)
		if status == http.StatusUnauthorized || status == http.StatusForbidden {
			// Nothing about the attendee's own token can cause this: the AI
			// service authenticates nobody, so its gateway is what rejected us
			// -- credentials absent, wrong, or not subscribed to its API.
			logMsg += credentialHint
		}
	default:
		if tokenStatus, isTokenFailure := aiagent.TokenFetchStatusFrom(err); isTokenFailure {
			logMsg = fmt.Sprintf("%s: OAuth2 token request for the AI service returned HTTP %d%s", logMsg, tokenStatus, credentialHint)
		}
	}
	slog.ErrorContext(c.Request.Context(), logMsg, "error", err)
	if aiServiceUnreachable(err) {
		c.JSON(http.StatusServiceUnavailable, gin.H{"message": "AI service is temporarily unavailable"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
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
