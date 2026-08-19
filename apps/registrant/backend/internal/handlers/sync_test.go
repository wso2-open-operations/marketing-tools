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
}

func (m *mockSheetsClient) SyncAttendeeSummary(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error {
	return m.syncAttendeeSummaryFn(ctx, summaries, timeZoneOffset)
}

func newSyncRouter(h *SyncHandler) *gin.Engine {
	r := gin.New()
	r.POST("/attendees/sync", h.SyncAttendees)
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
		h := NewSyncHandler(&mockSummaryRepo{}, &mockSheetsClient{})
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
		h := NewSyncHandler(&mockSummaryRepo{}, &mockSheetsClient{})
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
