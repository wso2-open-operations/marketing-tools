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

// EventReader reads event/agenda data. Satisfied by *repository.EventRepo.
type EventReader interface {
	GetEvents(ctx context.Context) ([]models.Event, error)
	GetCurrentEvent(ctx context.Context) (models.Event, error)
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

// List handles GET /events. With ?previous=true it returns only the
// non-current events (every event whose IsCurrent is false) for the
// events-history modal, so the client stops filtering previous events in the
// browser. Any other value, or the param's absence, returns all events
// unchanged. "Current" stays defined in one place -- the repository's
// latest-start_date rule -- and this only filters on the IsCurrent flag it
// already computes.
func (h *EventHandler) List(c *gin.Context) {
	events, err := h.reader.GetEvents(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching events failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	if c.Query("previous") == "true" {
		previous := make([]models.Event, 0, len(events))
		for _, e := range events {
			if !e.IsCurrent {
				previous = append(previous, e)
			}
		}
		events = previous
	}

	if events == nil {
		events = []models.Event{}
	}
	c.JSON(http.StatusOK, events)
}

// Current handles GET /events/current, returning the current conference as a
// single object rather than an array.
//
// The client (useCurrentEvent) reads `event.id` from this and pins every later
// request to it, so it must be one object: an array would leave the client
// reading `.id` off undefined. 404 when no conference exists at all.
//
// This route cannot collide with GET /events/:eventId/agendas whatever the
// registration order: that path is three segments and this one is two. The
// static-beats-wildcard rule gin applies is what would matter for a same-depth
// pair -- /sessions/current against /sessions/:id -- and it is that rule, not
// ordering, that a future bare /events/:eventId would rely on.
func (h *EventHandler) Current(c *gin.Context) {
	event, err := h.reader.GetCurrentEvent(c.Request.Context())
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"message": "no current event"})
			return
		}
		slog.ErrorContext(c.Request.Context(), "fetching current event failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.JSON(http.StatusOK, event)
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

// respondAgendas serves both agenda routes. eventID is either the literal
// "current" or a conference_config id, which is a uuid column -- so anything
// else is a malformed request, and gets the same guard the :id handlers apply
// rather than a 500 from the cast.
func (h *EventHandler) respondAgendas(c *gin.Context, eventID string) {
	if eventID != "current" && !uuidPattern.MatchString(eventID) {
		c.JSON(http.StatusBadRequest, gin.H{"message": "eventId must be a valid UUID"})
		return
	}

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
