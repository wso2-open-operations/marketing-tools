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
// One case is deliberately excluded: a token fetch the OAuth2 provider
// *rejected* also travels as a *url.Error, because the oauth2 transport fails
// the request before it is ever sent. Credentials that are wrong or not
// subscribed are a deployment error that will never fix itself, so calling
// them "temporarily unavailable" would be a lie that hides the one thing worth
// acting on. That is true only of the terminal statuses -- everything else the
// token endpoint answers is retriable and stays a 503: Asgardeo replies 429
// when it throttles and 5xx during an incident, both of which clear in
// seconds, and a RetrieveError carrying no response at all says nothing about
// the credentials either.
func aiServiceUnreachable(err error) bool {
	if status, isTokenFailure := aiagent.TokenFetchStatusFrom(err); isTokenFailure {
		return !tokenCredentialsRejected(status)
	}
	var urlErr *url.Error
	return errors.As(err, &urlErr)
}

// tokenCredentialsRejected reports whether a status from the OAuth2 token
// endpoint means the credentials themselves were refused, as opposed to the
// endpoint being momentarily unable to serve them. RFC 6749 answers an invalid
// client or grant with 400/401, and Choreo answers an application that is not
// subscribed to the target API with 403; nothing else is terminal.
func tokenCredentialsRejected(status int) bool {
	return status == http.StatusBadRequest ||
		status == http.StatusUnauthorized ||
		status == http.StatusForbidden
}

// gatewayRejectedCredentials reports whether an upstream status means the AI
// gateway refused *this service's* token, rather than anything the attendee
// sent. con-ai authenticates nobody -- its own caller check never rejects -- so
// a 401 or 403 from that hop can only have come from the managed gateway in
// front of it.
func gatewayRejectedCredentials(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden
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
	var attrs []any
	var statusErr *aiagent.StatusError
	switch {
	case errors.As(err, &statusErr):
		logMsg = fmt.Sprintf("%s: AI service returned HTTP %d", logMsg, statusErr.StatusCode)
		attrs = append(attrs, "upstreamStatus", statusErr.StatusCode, "upstreamURL", statusErr.URL)
		// The upstream body is never logged wholesale: con-ai is FastAPI, and
		// its 422 quotes the rejected input straight back -- the attendee's
		// chat question and history, or their name and email -- which would put
		// attendee data in the log store. A 401/403 body is the exception
		// worth keeping: it comes from the gateway, not con-ai, so it holds no
		// attendee data, and its `900901`/`900908` code is the fact a debugger
		// is actually after.
		if gatewayRejectedCredentials(statusErr.StatusCode) {
			// Nothing about the attendee's own token can cause this: the AI
			// service authenticates nobody, so its gateway is what rejected us
			// -- credentials absent, wrong, or not subscribed to its API.
			logMsg += credentialHint
			attrs = append(attrs, "upstreamBody", statusErr.Body)
		}
	default:
		if tokenStatus, isTokenFailure := aiagent.TokenFetchStatusFrom(err); isTokenFailure {
			logMsg = fmt.Sprintf("%s: OAuth2 token request for the AI service returned HTTP %d", logMsg, tokenStatus)
			// A throttled or briefly broken token endpoint (429/5xx) is not a
			// credential fault, and telling an operator to go re-check
			// AI_CLIENT_SECRET over an incident that clears itself sends them
			// after the wrong thing.
			if tokenCredentialsRejected(tokenStatus) {
				logMsg += credentialHint
			}
		}
		// Safe here only because err is not a *aiagent.StatusError: its
		// Error() ends with up to 2 KiB of the upstream body, which is the
		// attendee data the case above is careful to keep out.
		attrs = append(attrs, "error", err)
	}
	slog.ErrorContext(c.Request.Context(), logMsg, attrs...)
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
