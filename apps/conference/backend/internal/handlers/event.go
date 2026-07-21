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

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
)

// EventReader reads event/agenda data. Satisfied by *repository.EventRepo.
type EventReader interface {
	GetEvents(ctx context.Context) ([]models.Event, error)
	GetEventAgendas(ctx context.Context, eventID string) ([]models.EventAgenda, error)
}

// EventHandler handles authenticated event/agenda HTTP endpoints.
// Routes are registered under the JWT-gated api group in main.go.
type EventHandler struct {
	reader EventReader
}

// NewEventHandler constructs an EventHandler.
func NewEventHandler(reader EventReader) *EventHandler {
	return &EventHandler{reader: reader}
}

// List handles GET /events.
func (h *EventHandler) List(c *gin.Context) {
	events, err := h.reader.GetEvents(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching events failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if events == nil {
		events = []models.Event{}
	}
	c.JSON(http.StatusOK, events)
}

// Agendas handles GET /events/:eventId/agendas. eventId is passed straight
// through to GetEventAgendas, including the literal "current".
func (h *EventHandler) Agendas(c *gin.Context) {
	h.respondAgendas(c, c.Param("eventId"))
}

// LegacyAgendas handles GET /event-agendas?isCurrent=&eventId=, replicating
// the old Ballerina resolution order: isCurrent=true with no eventId
// resolves to "current"; otherwise the given eventId is used. If neither is
// supplied, this returns 400 -- a deliberate improvement over the old
// behavior, which fell through to a bare int conversion error and a 500 (see
// .claude/PLAN.md).
func (h *EventHandler) LegacyAgendas(c *gin.Context) {
	eventID := c.Query("eventId")
	isCurrent := c.Query("isCurrent") == "true"

	switch {
	case isCurrent && eventID == "":
		eventID = "current"
	case eventID != "":
		// use eventID as given
	default:
		c.JSON(http.StatusBadRequest, gin.H{"message": "eventId or isCurrent=true is required"})
		return
	}

	h.respondAgendas(c, eventID)
}

func (h *EventHandler) respondAgendas(c *gin.Context, eventID string) {
	agendas, err := h.reader.GetEventAgendas(c.Request.Context(), eventID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching event agendas failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if agendas == nil {
		agendas = []models.EventAgenda{}
	}
	c.JSON(http.StatusOK, agendas)
}
