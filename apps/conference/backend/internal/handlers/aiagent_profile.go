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

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// PersonalizedProfile handles POST /users/profile. The external personalize
// agent service's response is copied through verbatim -- status code,
// Content-Type, and body -- not decoded/re-typed, matching the old
// raw-passthrough behavior exactly. A 500 is only returned when the client
// call itself fails (the external service is unreachable); any actual
// response from it, even a 4xx/5xx one, passes through as-is (see
// .claude/PLAN.md).
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

	resp, err := h.client.SendProfileInfo(c.Request.Context(), user.RawToken, profile)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "sending profile info failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		c.Writer.Header().Set("Content-Type", ct)
	}
	c.Status(resp.StatusCode)
	if _, err := io.Copy(c.Writer, resp.Body); err != nil {
		slog.ErrorContext(c.Request.Context(), "copying profile response body failed", "error", err)
	}
}
