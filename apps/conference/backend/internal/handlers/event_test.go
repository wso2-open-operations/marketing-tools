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
	"wso2-coin-backend/internal/repository"
)

type fakeEventReader struct {
	events       []models.Event
	eventsErr    error
	current      models.Event
	currentErr   error
	agendas      []models.EventAgenda
	agendasErr   error
	lastEventID  string
	currentCalls int
}

func (f *fakeEventReader) GetEvents(ctx context.Context) ([]models.Event, error) {
	return f.events, f.eventsErr
}

func (f *fakeEventReader) GetCurrentEvent(ctx context.Context) (models.Event, error) {
	f.currentCalls++
	return f.current, f.currentErr
}

func (f *fakeEventReader) GetEventAgendas(ctx context.Context, eventID string) ([]models.EventAgenda, error) {
	f.lastEventID = eventID
	return f.agendas, f.agendasErr
}

func newEventTestRouter(h *EventHandler) *gin.Engine {
	r := gin.New()
	r.GET("/events", h.List)
	// Registered in the same order as main.go so these tests exercise the real
	// static-before-wildcard resolution rather than a simplified table.
	r.GET("/events/current", h.Current)
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

func TestEventHandler_List_PreviousTrueReturnsOnlyNonCurrent(t *testing.T) {
	reader := &fakeEventReader{events: []models.Event{
		{ID: "current-1", Name: "Latest", IsCurrent: true},
		{ID: "past-1", Name: "Older", IsCurrent: false},
		{ID: "past-2", Name: "Oldest", IsCurrent: false},
	}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events?previous=true", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	var got []models.Event
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len(got) = %d, want 2 (the current event filtered out)", len(got))
	}
	for _, e := range got {
		if e.IsCurrent {
			t.Errorf("previous=true returned a current event: %+v", e)
		}
	}
}

func TestEventHandler_List_ParamAbsentReturnsAll(t *testing.T) {
	reader := &fakeEventReader{events: []models.Event{
		{ID: "current-1", IsCurrent: true},
		{ID: "past-1", IsCurrent: false},
	}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events", nil)

	var got []models.Event
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("len(got) = %d, want 2 (unfiltered)", len(got))
	}
}

func TestEventHandler_List_PreviousTrueWithOnlyCurrentReturnsEmptyArray(t *testing.T) {
	reader := &fakeEventReader{events: []models.Event{{ID: "current-1", IsCurrent: true}}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events?previous=true", nil)

	if body := rec.Body.String(); body != "[]" {
		t.Errorf("body = %q, want %q", body, "[]")
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
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events/"+testEventID+"/agendas", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != testEventID {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, testEventID)
	}
}

func TestEventHandler_Agendas_PassesLiteralCurrentThrough(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events/current/agendas", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != "current" {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, "current")
	}
}

func TestEventHandler_Agendas_RepositoryErrorReturns500(t *testing.T) {
	h := NewEventHandler(&fakeEventReader{agendasErr: errBoom})
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/events/"+testEventID+"/agendas", nil)

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
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId="+testEventID, nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != testEventID {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, testEventID)
	}
}

func TestEventHandler_LegacyAgendas_ExplicitEventIDTakesPrecedenceOverIsCurrentFalse(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId="+testEventID+"&isCurrent=false", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != testEventID {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, testEventID)
	}
}

func TestEventHandler_LegacyAgendas_ExplicitEventIDTakesPrecedenceOverIsCurrentTrue(t *testing.T) {
	reader := &fakeEventReader{agendas: []models.EventAgenda{}}
	h := NewEventHandler(reader)
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId="+testEventID+"&isCurrent=true", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastEventID != testEventID {
		t.Errorf("lastEventID = %q, want %q", reader.lastEventID, testEventID)
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
	rec := doRequest(newEventTestRouter(h), http.MethodGet, "/event-agendas?eventId="+testEventID, nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

// The client reads `event.id` off this and pins every later request to it, so it
// must be a single object -- an array would leave it reading .id off undefined.
func TestEventHandler_Current_ReturnsSingleObject(t *testing.T) {
	reader := &fakeEventReader{current: models.Event{
		ID: "event-1", Name: "WSO2Con Africa", IsCurrent: true, Timezone: "Africa/Nairobi",
	}}
	rec := doRequest(newEventTestRouter(NewEventHandler(reader)), http.MethodGet, "/events/current", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var got models.Event
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not a single event object: %v (%s)", err, rec.Body.String())
	}
	if got.ID != "event-1" {
		t.Errorf("id = %q, want event-1", got.ID)
	}
	if !got.IsCurrent {
		t.Error("isCurrent = false, want true")
	}
	if got.Timezone != "Africa/Nairobi" {
		t.Errorf("timezone = %q, want Africa/Nairobi", got.Timezone)
	}
}

func TestEventHandler_Current_NoEventIs404(t *testing.T) {
	reader := &fakeEventReader{currentErr: repository.ErrNotFound}
	rec := doRequest(newEventTestRouter(NewEventHandler(reader)), http.MethodGet, "/events/current", nil)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestEventHandler_Current_RepoErrorIs500(t *testing.T) {
	reader := &fakeEventReader{currentErr: errBoom}
	rec := doRequest(newEventTestRouter(NewEventHandler(reader)), http.MethodGet, "/events/current", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

// /events/current must not be swallowed by the /events/:eventId/agendas wildcard
// registered alongside it. Registering both is what this asserts is safe.
func TestEventHandler_Current_DoesNotCollideWithEventIDWildcard(t *testing.T) {
	reader := &fakeEventReader{
		current: models.Event{ID: "event-1"},
		agendas: []models.EventAgenda{{ID: "day-1"}},
	}
	r := newEventTestRouter(NewEventHandler(reader))

	if rec := doRequest(r, http.MethodGet, "/events/current", nil); rec.Code != http.StatusOK {
		t.Fatalf("/events/current returned %d", rec.Code)
	}
	if reader.currentCalls != 1 {
		t.Errorf("GetCurrentEvent called %d times, want 1", reader.currentCalls)
	}

	// The wildcard route still works, and still receives the literal id.
	if rec := doRequest(r, http.MethodGet, "/events/"+testEventID+"/agendas", nil); rec.Code != http.StatusOK {
		t.Fatalf("/events/abc-123/agendas returned %d", rec.Code)
	}
	if reader.lastEventID != testEventID {
		t.Errorf("agendas got eventId %q, want %q", reader.lastEventID, testEventID)
	}
}

// conference_config.id is a uuid column, so a non-UUID eventId is a malformed
// request, not a server fault. Both agenda routes skipped the guard the :id
// handlers already apply and 500'd on the cast error instead.
func TestEventHandler_Agendas_NonUUIDEventIDReturns400(t *testing.T) {
	reader := &fakeEventReader{}
	r := newEventTestRouter(NewEventHandler(reader))

	w := doRequest(r, http.MethodGet, "/events/not-a-uuid/agendas", nil)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
	if reader.lastEventID != "" {
		t.Errorf("repository should not have been called, got eventID %q", reader.lastEventID)
	}
}

func TestEventHandler_LegacyAgendas_NonUUIDEventIDReturns400(t *testing.T) {
	reader := &fakeEventReader{}
	r := newEventTestRouter(NewEventHandler(reader))

	w := doRequest(r, http.MethodGet, "/event-agendas?eventId=not-a-uuid", nil)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
	if reader.lastEventID != "" {
		t.Errorf("repository should not have been called, got eventID %q", reader.lastEventID)
	}
}
