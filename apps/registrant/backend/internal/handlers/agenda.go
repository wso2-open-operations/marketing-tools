// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package handlers

import (
	"log/slog"
	"net/http"
	"strconv"

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

	// The Ballerina route typed this path segment as `int`, so a non-numeric
	// value never reached the handler (404 from routing). Mirror that here.
	agendaID, err := strconv.Atoi(c.Param("agendaId"))
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}

	count, err := h.repo.GetAgendaAttendeeCount(c.Request.Context(), agendaID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error retrieving count of attendees for an agenda.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.JSON(http.StatusOK, count)
}
