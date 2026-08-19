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
)

type AgendaHandler struct {
	repo AgendaRepository
}

func NewAgendaHandler(repo AgendaRepository) *AgendaHandler {
	return &AgendaHandler{repo: repo}
}

// ListCurrentAgendas handles GET /events/current/agendas.
func (h *AgendaHandler) ListCurrentAgendas(c *gin.Context) {
	if _, ok := requireUserInfo(c); !ok {
		return
	}

	event, err := h.repo.GetCurrentEvent(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error retrieving current event", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	agendas, err := h.repo.GetAgendas(c.Request.Context(), event.ID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error retrieving list of agendas.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.JSON(http.StatusOK, agendas)
}

type registerAttendeePayload struct {
	AttendeeID string `json:"attendeeId" binding:"required"`
}

// RegisterAttendee handles POST /agendas/:agendaId/attendees.
func (h *AgendaHandler) RegisterAttendee(c *gin.Context) {
	userInfo, ok := requireUserInfo(c)
	if !ok {
		return
	}

	agendaID := c.Param("agendaId")

	var payload registerAttendeePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.Status(http.StatusBadRequest)
		return
	}

	existing, err := h.repo.GetAgendaAttendee(c.Request.Context(), payload.AttendeeID, agendaID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error registering attendee.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}
	if existing != nil {
		c.String(http.StatusConflict, "Attendee already registered for the agenda.")
		return
	}

	if err := h.repo.InsertAgendaAttendee(c.Request.Context(), payload.AttendeeID, agendaID, userInfo.Email); err != nil {
		slog.ErrorContext(c.Request.Context(), "Error registering attendee.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.Status(http.StatusCreated)
}

// AttendeeCount handles GET /agendas/:agendaId/attendees/count.
func (h *AgendaHandler) AttendeeCount(c *gin.Context) {
	if _, ok := requireUserInfo(c); !ok {
		return
	}

	agendaID := c.Param("agendaId")

	count, err := h.repo.GetAgendaAttendeeCount(c.Request.Context(), agendaID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error retrieving count of attendees for an agenda.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.JSON(http.StatusOK, count)
}
