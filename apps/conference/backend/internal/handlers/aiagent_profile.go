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
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/clients/aiagent"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// maxProfileErrBodyBytes caps how much of a rejected upstream response is read
// for the log line, mirroring the same cap in clients/aiagent so an unexpected
// body cannot blow up the log store.
const maxProfileErrBodyBytes = 2048

// PersonalizedProfile handles POST /users/profile. The external personalize
// agent service's response is copied through verbatim -- status code,
// Content-Type, and body -- not decoded/re-typed, matching the old
// raw-passthrough behavior exactly. A 500 is returned when the client call
// itself fails (the external service is unreachable) and when the AI gateway
// refuses this service's credentials (see below); any other response, even a
// 4xx/5xx one, passes through as-is (see .claude/PLAN.md).
//
// The profile's `email` is the key the AI service upserts on, so it is
// overwritten with the caller's JWT email. A body value is ignored, not
// rejected: con-ai dropped its own auth, this handler is the only gate, and a
// stale client sending its own email must keep working rather than start
// 403ing (audit D2). Everything else in the payload, `override` included, is
// unchanged.
func (h *AIAgentHandler) PersonalizedProfile(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var profile models.PersonalizeAgentUserProfile
	if err := c.ShouldBindJSON(&profile); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	// Personalized profile creation is gated on the personalized-agenda flag
	// (shared with GET /agenda/recommendations). Disabled -> clean 503 rather
	// than a raw 500 from an unreachable backend (defense-in-depth alongside
	// AI_ENABLED_PERSONALIZED_AGENDA).
	if !h.featureStatus.EnabledPersonalizedAgenda {
		respondFeatureDisabled(c, "Personalized agenda")
		return
	}

	if profile.Email != "" && !strings.EqualFold(profile.Email, user.Email) {
		slog.WarnContext(c.Request.Context(), "ignoring profile email from request body",
			"bodyEmail", profile.Email)
	}
	profile.Email = user.Email

	resp, err := h.client.SendProfileInfo(c.Request.Context(), user.RawToken, profile)
	if err != nil {
		respondAIUpstreamError(c, "sending profile info failed", err)
		return
	}
	defer resp.Body.Close()

	// The only exception to the verbatim passthrough above. con-ai performs no
	// authentication of its own and its error envelope is {"message": ...},
	// never {"error_message":..., "code":...}, so a 401 or 403 on this hop is
	// always the managed gateway refusing *this service's* token -- never
	// con-ai, and never anything the attendee sent. Relaying it verbatim
	// handed the attendee the gateway's `900901` taxonomy, and a 401 on an
	// ordinary API call is what a frontend auth interceptor reads as an expired
	// session: a credential fault on this backend turned into a logout and
	// re-auth loop on every attendee's phone. Routing it through
	// respondAIUpstreamError instead yields the same generic 500 plus the
	// credential hint the other five AI routes emit -- which this route could
	// otherwise never reach, since err is nil on this path. Every other status
	// keeps relaying byte-for-byte, con-ai's own 4xx (a FastAPI 422) included.
	if gatewayRejectedCredentials(resp.StatusCode) {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxProfileErrBodyBytes))
		respondAIUpstreamError(c, "sending profile info failed", &aiagent.StatusError{
			StatusCode: resp.StatusCode,
			URL:        requestURLOf(resp),
			Body:       string(errBody),
		})
		return
	}

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		c.Writer.Header().Set("Content-Type", ct)
	}
	c.Status(resp.StatusCode)
	if _, err := io.Copy(c.Writer, resp.Body); err != nil {
		slog.ErrorContext(c.Request.Context(), "copying profile response body failed", "error", err)
	}
}

// requestURLOf reports the URL a response came from. http.Client fills
// Response.Request in, but a response assembled by hand (a test double) has
// none, so this must not assume it.
func requestURLOf(resp *http.Response) string {
	if resp.Request == nil || resp.Request.URL == nil {
		return ""
	}
	return resp.Request.URL.String()
}
