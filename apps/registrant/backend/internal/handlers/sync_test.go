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
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"attendee-registration/internal/email"
	"attendee-registration/internal/repository"
	"attendee-registration/internal/sheets"

	"github.com/gin-gonic/gin"
)

type mockSummaryRepo struct {
	getAttendeeSummaryFn func(ctx context.Context) ([]repository.AttendeeSummary, error)
}

func (m *mockSummaryRepo) GetAttendeeSummary(ctx context.Context) ([]repository.AttendeeSummary, error) {
	return m.getAttendeeSummaryFn(ctx)
}

type mockSheetsClient struct {
	syncAttendeeSummaryFn func(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error
	getSheetDataFn        func(ctx context.Context) ([]sheets.Attendee, error)
	updateAttendeeDataFn  func(ctx context.Context, rowIndex int, attendee sheets.Attendee) error
}

func (m *mockSheetsClient) SyncAttendeeSummary(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error {
	return m.syncAttendeeSummaryFn(ctx, summaries, timeZoneOffset)
}

func (m *mockSheetsClient) GetSheetData(ctx context.Context) ([]sheets.Attendee, error) {
	return m.getSheetDataFn(ctx)
}

func (m *mockSheetsClient) UpdateAttendeeData(ctx context.Context, rowIndex int, attendee sheets.Attendee) error {
	if m.updateAttendeeDataFn != nil {
		return m.updateAttendeeDataFn(ctx, rowIndex, attendee)
	}
	return nil
}

type mockEmailClient struct {
	sendFn func(ctx context.Context, payload email.Payload) error
}

func (m *mockEmailClient) Send(ctx context.Context, payload email.Payload) error {
	if m.sendFn != nil {
		return m.sendFn(ctx, payload)
	}
	return nil
}

func newSyncRouter(h *SyncHandler) *gin.Engine {
	r := gin.New()
	r.POST("/attendees/sync", h.SyncAttendees)
	r.POST("/invitations/notifications", h.SendInvitationNotifications)
	return r
}

func TestSyncAttendees(t *testing.T) {
	t.Run("200 syncs summary", func(t *testing.T) {
		var gotOffset float64
		var gotSummaries []sheets.AttendeeSummary
		h := NewSyncHandler(
			&mockSummaryRepo{getAttendeeSummaryFn: func(ctx context.Context) ([]repository.AttendeeSummary, error) {
				return []repository.AttendeeSummary{{Agenda: "Day 1", Username: "a@wso2.com", UserType: "Internal"}}, nil
			}},
			&mockSheetsClient{syncAttendeeSummaryFn: func(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error {
				gotOffset = timeZoneOffset
				gotSummaries = summaries
				return nil
			}},
			&mockEmailClient{},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/attendees/sync", bytes.NewBufferString(`{"timeZoneOffset":5.5}`))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		if gotOffset != 5.5 {
			t.Errorf("offset = %v, want 5.5", gotOffset)
		}
		if len(gotSummaries) != 1 || gotSummaries[0].Agenda != "Day 1" {
			t.Errorf("summaries = %+v", gotSummaries)
		}
	})

	t.Run("500 missing user info", func(t *testing.T) {
		h := NewSyncHandler(&mockSummaryRepo{}, &mockSheetsClient{}, &mockEmailClient{}, "noreply@example.com")
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/attendees/sync", bytes.NewBufferString(`{"timeZoneOffset":0}`))
		req.Header.Set("Content-Type", "application/json")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("400 bad JSON", func(t *testing.T) {
		h := NewSyncHandler(&mockSummaryRepo{}, &mockSheetsClient{}, &mockEmailClient{}, "noreply@example.com")
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/attendees/sync", bytes.NewBufferString(`not json`))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", w.Code)
		}
	})

	t.Run("500 summary lookup fails", func(t *testing.T) {
		h := NewSyncHandler(
			&mockSummaryRepo{getAttendeeSummaryFn: func(ctx context.Context) ([]repository.AttendeeSummary, error) {
				return nil, errors.New("db down")
			}},
			&mockSheetsClient{},
			&mockEmailClient{},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/attendees/sync", bytes.NewBufferString(`{"timeZoneOffset":0}`))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 sheet sync fails", func(t *testing.T) {
		h := NewSyncHandler(
			&mockSummaryRepo{getAttendeeSummaryFn: func(ctx context.Context) ([]repository.AttendeeSummary, error) {
				return nil, nil
			}},
			&mockSheetsClient{syncAttendeeSummaryFn: func(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error {
				return errors.New("sheets down")
			}},
			&mockEmailClient{},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/attendees/sync", bytes.NewBufferString(`{"timeZoneOffset":0}`))
		req.Header.Set("Content-Type", "application/json")
		req = withUserInfo(req, "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})
}

func TestSendInvitationNotifications(t *testing.T) {
	t.Run("200 sends to unsent attendees only", func(t *testing.T) {
		var sentTo []string
		var updatedRows []int
		h := NewSyncHandler(
			&mockSummaryRepo{},
			&mockSheetsClient{
				getSheetDataFn: func(ctx context.Context) ([]sheets.Attendee, error) {
					return []sheets.Attendee{
						{Email: "already@wso2.com", UUID: "u1", IsInviteSent: true},
						{Email: "pending@wso2.com", UUID: "u2", IsInviteSent: false},
					}, nil
				},
				updateAttendeeDataFn: func(ctx context.Context, rowIndex int, attendee sheets.Attendee) error {
					updatedRows = append(updatedRows, rowIndex)
					if !attendee.IsInviteSent {
						t.Errorf("expected IsInviteSent=true when updating, got false")
					}
					return nil
				},
			},
			&mockEmailClient{sendFn: func(ctx context.Context, payload email.Payload) error {
				sentTo = append(sentTo, payload.To...)
				return nil
			}},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodPost, "/invitations/notifications", nil), "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		if len(sentTo) != 1 || sentTo[0] != "pending@wso2.com" {
			t.Errorf("sentTo = %v, want [pending@wso2.com]", sentTo)
		}
		if len(updatedRows) != 1 || updatedRows[0] != 3 {
			t.Errorf("updatedRows = %v, want [3] (index 1 + 2)", updatedRows)
		}
	})

	t.Run("continues after a send failure", func(t *testing.T) {
		var sentTo []string
		h := NewSyncHandler(
			&mockSummaryRepo{},
			&mockSheetsClient{
				getSheetDataFn: func(ctx context.Context) ([]sheets.Attendee, error) {
					return []sheets.Attendee{
						{Email: "fails@wso2.com", UUID: "u1"},
						{Email: "succeeds@wso2.com", UUID: "u2"},
					}, nil
				},
			},
			&mockEmailClient{sendFn: func(ctx context.Context, payload email.Payload) error {
				if payload.To[0] == "fails@wso2.com" {
					return errors.New("send failed")
				}
				sentTo = append(sentTo, payload.To...)
				return nil
			}},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodPost, "/invitations/notifications", nil), "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		if len(sentTo) != 1 || sentTo[0] != "succeeds@wso2.com" {
			t.Errorf("sentTo = %v, want [succeeds@wso2.com]", sentTo)
		}
	})

	t.Run("500 missing user info", func(t *testing.T) {
		h := NewSyncHandler(&mockSummaryRepo{}, &mockSheetsClient{}, &mockEmailClient{}, "noreply@example.com")
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/invitations/notifications", nil)
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})

	t.Run("500 sheet data fetch fails", func(t *testing.T) {
		h := NewSyncHandler(
			&mockSummaryRepo{},
			&mockSheetsClient{getSheetDataFn: func(ctx context.Context) ([]sheets.Attendee, error) {
				return nil, errors.New("sheets down")
			}},
			&mockEmailClient{},
			"noreply@example.com",
		)
		r := newSyncRouter(h)

		w := httptest.NewRecorder()
		req := withUserInfo(httptest.NewRequest(http.MethodPost, "/invitations/notifications", nil), "admin@wso2.com")
		r.ServeHTTP(w, req)

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
	})
}
