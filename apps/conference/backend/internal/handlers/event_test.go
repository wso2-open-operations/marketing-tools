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
	"encoding/json"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
)

type fakeEventReader struct {
	events      []models.Event
	eventsErr   error
	agendas     []models.EventAgenda
	agendasErr  error
	lastEventID string
}

func (f *fakeEventReader) GetEvents(ctx context.Context) ([]models.Event, error) {
	return f.events, f.eventsErr
}

func (f *fakeEventReader) GetEventAgendas(ctx context.Context, eventID string) ([]models.EventAgenda, error) {
	f.lastEventID = eventID
	return f.agendas, f.agendasErr
}

func newEventTestRouter(h *EventHandler) *gin.Engine {
	r := gin.New()
	r.GET("/events", h.List)
	r.GET("/events/:eventId/agendas", h.Agendas)
	r.GET("/event-agendas", h.LegacyAgendas)
	return r
}

func TestEventHandler_List_ReturnsEvents(t *testing.T) {
	reader := &fakeEventReader{events: []models.Event{{ID: "event-1", Name: "WSO2Con NA", IsCurrent: true}}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	var got []models.Event
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got) != 1 || got[0].ID != "event-1" {
		t.Errorf("unexpected body: %+v", got)
	}
}

func TestEventHandler_List_EmptyResultReturnsEmptyArrayNotNull(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{events: nil})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if body := rec.Body.String(); body != "[]" {
		t.Errorf("body = %q, want %q", body, "[]")
	}
}

func TestEventHandler_List_RepositoryErrorReturns500(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{eventsErr: errBoom})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

func TestEventHandler_Agendas_PassesEventIDThrough(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{{ID: "day-1", EventID: "event-1", Date: "2026-05-20", Sessions: []models.Session{}}}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events/event-1/agendas", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != "event-1" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "event-1")
	}
}

func TestEventHandler_Agendas_PassesLiteralCurrentThrough(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	doRequest(newEventTestRouter(h), http.MethodGet, "/events/current/agendas", nil)

	if reader.lastEventID != "current" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "current")
	}
}

func TestEventHandler_Agendas_RepositoryErrorReturns500(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{agendasErr: errBoom})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events/event-1/agendas", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

func TestEventHandler_LegacyAgendas_IsCurrentTrueWithNoEventIDResolvesToCurrent(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?isCurrent=true", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != "current" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "current")
	}
}

func TestEventHandler_LegacyAgendas_ExplicitEventIDUsedAsGiven(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId=event-1", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != "event-1" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "event-1")
	}
}

func TestEventHandler_LegacyAgendas_ExplicitEventIDTakesPrecedenceOverIsCurrentFalse(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId=event-1&isCurrent=false", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != "event-1" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "event-1")
	}
}

func TestEventHandler_LegacyAgendas_NeitherSuppliedReturns400(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas", nil)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}

func TestEventHandler_LegacyAgendas_RepositoryErrorReturns500(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{agendasErr: errBoom})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId=event-1", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}
