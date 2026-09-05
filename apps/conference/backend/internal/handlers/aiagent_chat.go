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
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// Chat handles POST /assistant/chat, forwarding the whole request to the
// external chat service. Responds 201 on success -- matches the old code's
// 201-for-a-chat-POST exactly, an existing convention worth preserving as-is
// rather than "fixed" to 200 (see .claude/PLAN.md).
func (h *AIAgentHandler) Chat(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.ChatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	// Gate on the chat flag before calling the external service, so a disabled
	// assistant degrades to a clean 503 rather than a raw 500 from an
	// unreachable backend (defense-in-depth alongside AI_ENABLED_CHAT_ASSISTANT).
	if !h.featureStatus.EnabledChatAssistant {
		respondFeatureDisabled(c, "Chat assistant")
		return
	}

	resp, err := h.client.RetrieveChatResponse(c.Request.Context(), user.RawToken, req)
	if err != nil {
		respondAIUpstreamError(c, "retrieving chat response failed", err)
		return
	}
	c.JSON(http.StatusCreated, resp)
}
