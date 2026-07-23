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
	"log/slog"
	"net/http"
	"regexp"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
)

// FeedbackReader is satisfied by *repository.FeedbackRepo.
type FeedbackReader interface {
	Insert(ctx context.Context, in models.FeedbackInsert) error
}

// sessionIDPattern matches the textual form of a UUID. session_id is a UUID
// column; without this check a malformed value reaches Postgres and its
// conversion error surfaces as a 500 instead of a 400.
var sessionIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// FeedbackHandler exposes the feedback HTTP endpoint.
type FeedbackHandler struct {
	feedback FeedbackReader
	events   EventReader
}

// NewFeedbackHandler constructs a FeedbackHandler. events resolves the
// current conference for EVENT-type feedback -- reuses EventRepo.GetEvents
// instead of a second "current event" query (see .claude/PLAN.md).
func NewFeedbackHandler(feedback FeedbackReader, events EventReader) *FeedbackHandler {
	return &FeedbackHandler{feedback: feedback, events: events}
}

// Create handles POST /feedback. Unlike the old code, a SESSION-type
// submission with no sessionId returns 400, not 500 -- user-confirmed fix,
// see .claude/PLAN.md.
func (h *FeedbackHandler) Create(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.FeedbackRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	if !req.FeedbackType.IsValid() {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid feedback type"})
		return
	}

	in := models.FeedbackInsert{
		UserUUID:     user.UserID,
		FeedbackType: req.FeedbackType,
		Rating:       req.Rating,
		Comment:      req.Comment,
	}

	// SessionID/EventID are populated exclusively based on FeedbackType,
	// never both -- a client sending a sessionId on an EVENT-type request
	// has it ignored, not persisted alongside the resolved event_id.
	if req.FeedbackType == models.FeedbackSession {
		if req.SessionID == nil {
			c.JSON(http.StatusBadRequest, gin.H{"message": "sessionId is required for session feedback"})
			return
		}
		if !sessionIDPattern.MatchString(*req.SessionID) {
			c.JSON(http.StatusBadRequest, gin.H{"message": "sessionId must be a valid UUID"})
			return
		}
		in.SessionID = req.SessionID
	} else {
		currentEvents, err := h.events.GetEvents(c.Request.Context())
		if err != nil {
			slog.ErrorContext(c.Request.Context(), "fetching current event failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
			return
		}
		if len(currentEvents) == 0 {
			slog.ErrorContext(c.Request.Context(), "no current event to attach event feedback to")
			c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
			return
		}
		in.EventID = &currentEvents[0].ID
	}

	if err := h.feedback.Insert(c.Request.Context(), in); err != nil {
		slog.ErrorContext(c.Request.Context(), "inserting feedback failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.Status(http.StatusCreated)
}
