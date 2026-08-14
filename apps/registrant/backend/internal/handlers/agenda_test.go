// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"attendee-registration/internal/middleware"
	"attendee-registration/internal/repository"

	"github.com/gin-gonic/gin"
)

type mockAgendaRepo struct {
	getAgendasFn             func(ctx context.Context, eventID string) ([]repository.Agenda, error)
	insertAgendaAttendeeFn   func(ctx context.Context, attendeeID, agendaID, userEmail string) error
	getAgendaAttendeeFn      func(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error)
	getAgendaAttendeeCountFn func(ctx context.Context, agendaID int) (repository.AgendaAttendeeCount, error)
	getCurrentEventFn        func(ctx context.Context) (repository.Event, error)
}

func (m *mockAgendaRepo) GetAgendas(ctx context.Context, eventID string) ([]repository.Agenda, error) {
	return m.getAgendasFn(ctx, eventID)
}

func (m *mockAgendaRepo) InsertAgendaAttendee(ctx context.Context, attendeeID, agendaID, userEmail string) error {
	return m.insertAgendaAttendeeFn(ctx, attendeeID, agendaID, userEmail)
}

func (m *mockAgendaRepo) GetAgendaAttendee(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error) {
	return m.getAgendaAttendeeFn(ctx, attendeeID, agendaID)
}

func (m *mockAgendaRepo) GetAgendaAttendeeCount(ctx context.Context, agendaID int) (repository.AgendaAttendeeCount, error) {
	return m.getAgendaAttendeeCountFn(ctx, agendaID)
}

func (m *mockAgendaRepo) GetCurrentEvent(ctx context.Context) (repository.Event, error) {
	return m.getCurrentEventFn(ctx)
}

// newAgendaRouter wires a handler under real gin routes so tests exercise
// path-param binding and the same header-flush behavior a live server has —
// invoking handler methods directly bypasses gin's WriteHeaderNow finalization
// for bare c.Status() responses (no body write), which would misreport 200.
func newAgendaRouter(h *AgendaHandler) *gin.Engine {
	r := gin.New()
	r.GET("/events/current/agendas", h.ListCurrentAgendas)
	r.POST("/agendas/:agendaId/attendees", h.RegisterAttendee)
	r.GET("/agendas/:agendaId/attendees/count", h.AttendeeCount)
	return r
}

func withUserInfo(req *http.Request, email string) *http.Request {
	if email == "" {
		return req
	}
	ctx := middleware.WithUserInfo(req.Context(), &middleware.UserInfo{Email: email})
	return req.WithContext(ctx)
}

func TestListCurrentAgendas(t *testing.T) {
	t.Run("200 returns agendas", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getCurrentEventFn: func(ctx context.Context) (repository.Event, error) {
				return repository.Event{ID: "event-1"}, nil
			},
			getAgendasFn: func(ctx context.Context, eventID string) ([]repository.Agenda, error) {
				if eventID != "event-1" {
					t.Errorf("eventID = %q, want event-1", eventID)
				}
				return []repository.Agenda{{ID: 1, Name: "Day 1", Date: "2026-07-29"}}, nil
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/events/current/agendas", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		var got []repository.Agenda
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].Name != "Day 1" {
			t.Errorf("unexpected body: %+v", got)
		}
	})

	t.Run("500 missing user info", func(t *testing.T) {
		r := newAgendaRouter(NewAgendaHandler(&mockAgendaRepo{}))

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/events/current/agendas", nil)
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 event lookup fails", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getCurrentEventFn: func(ctx context.Context) (repository.Event, error) {
				return repository.Event{}, errors.New("db down")
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/events/current/agendas", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 agendas lookup fails", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getCurrentEventFn: func(ctx context.Context) (repository.Event, error) { return repository.Event{ID: "event-1"}, nil },
			getAgendasFn: func(ctx context.Context, eventID string) ([]repository.Agenda, error) {
				return nil, errors.New("db down")
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/events/current/agendas", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})
}

func TestRegisterAttendee(t *testing.T) {
	t.Run("201 registers new attendee", func(t *testing.T) {
		var insertedBy string
		repo := &mockAgendaRepo{
			getAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error) {
				return nil, nil
			},
			insertAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID, userEmail string) error {
				insertedBy = userEmail
				return nil
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		body, _ := json.Marshal(registerAttendeePayload{AttendeeID: "attendee@wso2.com"})
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusCreated {
			t.Fatalf("status = %d, want 201", w.Code)
		}
		if insertedBy != "admin@wso2.com" {
			t.Errorf("insertedBy = %q, want admin@wso2.com", insertedBy)
		}
	})

	t.Run("409 already registered", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error) {
				return &repository.AgendaAttendee{AttendeeID: attendeeID, AgendaID: 1}, nil
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		body, _ := json.Marshal(registerAttendeePayload{AttendeeID: "attendee@wso2.com"})
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusConflict {
			t.Fatalf("status = %d, want 409", w.Code)
		}
	})

	t.Run("400 missing attendeeId", func(t *testing.T) {
		r := newAgendaRouter(NewAgendaHandler(&mockAgendaRepo{}))

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewBufferString("{}"))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", w.Code)
		}
	})

	t.Run("500 missing user info", func(t *testing.T) {
		r := newAgendaRouter(NewAgendaHandler(&mockAgendaRepo{}))

		body, _ := json.Marshal(registerAttendeePayload{AttendeeID: "attendee@wso2.com"})
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 lookup fails", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error) {
				return nil, errors.New("db down")
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		body, _ := json.Marshal(registerAttendeePayload{AttendeeID: "attendee@wso2.com"})
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 insert fails", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error) {
				return nil, nil
			},
			insertAgendaAttendeeFn: func(ctx context.Context, attendeeID, agendaID, userEmail string) error {
				return errors.New("db down")
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		body, _ := json.Marshal(registerAttendeePayload{AttendeeID: "attendee@wso2.com"})
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/agendas/1/attendees", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})
}

func TestAttendeeCount(t *testing.T) {
	t.Run("200 returns count", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getAgendaAttendeeCountFn: func(ctx context.Context, agendaID int) (repository.AgendaAttendeeCount, error) {
				if agendaID != 1 {
					t.Errorf("agendaID = %d, want 1", agendaID)
				}
				return repository.AgendaAttendeeCount{InternalCount: 2, ExternalCount: 1, TotalCount: 3}, nil
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/agendas/1/attendees/count", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		var got repository.AgendaAttendeeCount
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		want := repository.AgendaAttendeeCount{InternalCount: 2, ExternalCount: 1, TotalCount: 3}
		if got != want {
			t.Errorf("got %+v, want %+v", got, want)
		}
	})

	t.Run("404 non-numeric agendaId", func(t *testing.T) {
		r := newAgendaRouter(NewAgendaHandler(&mockAgendaRepo{}))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/agendas/abc/attendees/count", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
	})

	t.Run("500 missing user info", func(t *testing.T) {
		r := newAgendaRouter(NewAgendaHandler(&mockAgendaRepo{}))

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/agendas/1/attendees/count", nil)
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 lookup fails", func(t *testing.T) {
		repo := &mockAgendaRepo{
			getAgendaAttendeeCountFn: func(ctx context.Context, agendaID int) (repository.AgendaAttendeeCount, error) {
				return repository.AgendaAttendeeCount{}, errors.New("db down")
			},
		}
		r := newAgendaRouter(NewAgendaHandler(repo))

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodGet, "/agendas/1/attendees/count", nil), "test@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})
}
