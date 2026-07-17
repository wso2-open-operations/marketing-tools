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
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// SpeakerReader reads speaker data. Satisfied by *repository.SpeakerRepo.
type SpeakerReader interface {
	GetSpeaker(ctx context.Context, id string) (models.Speaker, error)
	GetSpeakerSummary(ctx context.Context) ([]models.SpeakerSummary, error)
}

// SpeakerHandler exposes the public, unauthenticated speaker HTTP endpoints
// (conference speaker directory — not gated by x-jwt-assertion, matching the
// old Ballerina service where these routes work with no JWT present).
type SpeakerHandler struct {
	reader SpeakerReader
}

// NewSpeakerHandler constructs a SpeakerHandler.
func NewSpeakerHandler(reader SpeakerReader) *SpeakerHandler {
	return &SpeakerHandler{reader: reader}
}

// List handles GET /speakers.
func (h *SpeakerHandler) List(c *gin.Context) {
	summaries, err := h.reader.GetSpeakerSummary(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching speaker summary failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if summaries == nil {
		summaries = []models.SpeakerSummary{}
	}
	c.JSON(http.StatusOK, summaries)
}

// Get handles GET /speakers/:id.
func (h *SpeakerHandler) Get(c *gin.Context) {
	speaker, err := h.reader.GetSpeaker(c.Request.Context(), c.Param("id"))
	switch {
	case err == nil:
		c.JSON(http.StatusOK, speaker)
	case errors.Is(err, repository.ErrNotFound):
		c.Status(http.StatusNotFound)
	default:
		slog.ErrorContext(c.Request.Context(), "fetching speaker failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
	}
}
