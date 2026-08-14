// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import (
	"context"
	"errors"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func newMockRepo(t *testing.T) (*Repository, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock.New failed: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return New(db), mock
}

func TestGetAgendas(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"id", "name", "date"}).
		AddRow(1, "Day 1", "2026-07-29").
		AddRow(2, "Day 2", "2026-07-30")
	mock.ExpectQuery("SELECT id, name, date").WithArgs("event-1").WillReturnRows(rows)

	got, err := repo.GetAgendas(context.Background(), "event-1")
	if err != nil {
		t.Fatalf("GetAgendas failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 agendas, got %d", len(got))
	}
	if got[0].Name != "Day 1" || got[1].Name != "Day 2" {
		t.Errorf("unexpected agendas: %+v", got)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestGetAgendas_Empty(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"id", "name", "date"})
	mock.ExpectQuery("SELECT id, name, date").WithArgs("event-1").WillReturnRows(rows)

	got, err := repo.GetAgendas(context.Background(), "event-1")
	if err != nil {
		t.Fatalf("GetAgendas failed: %v", err)
	}
	if got == nil {
		t.Fatal("expected non-nil empty slice")
	}
	if len(got) != 0 {
		t.Errorf("expected 0 agendas, got %d", len(got))
	}
}

func TestInsertAgendaAttendee(t *testing.T) {
	repo, mock := newMockRepo(t)

	mock.ExpectExec("INSERT INTO agenda_attendee").
		WithArgs("attendee@wso2.com", "1", "admin@wso2.com").
		WillReturnResult(sqlmock.NewResult(1, 1))

	if err := repo.InsertAgendaAttendee(context.Background(), "attendee@wso2.com", "1", "admin@wso2.com"); err != nil {
		t.Fatalf("InsertAgendaAttendee failed: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestInsertAgendaAttendee_Error(t *testing.T) {
	repo, mock := newMockRepo(t)

	mock.ExpectExec("INSERT INTO agenda_attendee").
		WithArgs("attendee@wso2.com", "1", "admin@wso2.com").
		WillReturnError(errors.New("duplicate entry"))

	if err := repo.InsertAgendaAttendee(context.Background(), "attendee@wso2.com", "1", "admin@wso2.com"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestGetAgendaAttendee_Found(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"attendee_id", "agenda_id"}).AddRow("attendee@wso2.com", 1)
	mock.ExpectQuery("SELECT attendee_id, agenda_id").WithArgs("attendee@wso2.com", "1").WillReturnRows(rows)

	got, err := repo.GetAgendaAttendee(context.Background(), "attendee@wso2.com", "1")
	if err != nil {
		t.Fatalf("GetAgendaAttendee failed: %v", err)
	}
	if got == nil {
		t.Fatal("expected a result, got nil")
	}
	if got.AttendeeID != "attendee@wso2.com" || got.AgendaID != 1 {
		t.Errorf("unexpected result: %+v", got)
	}
}

func TestGetAgendaAttendee_NotFound(t *testing.T) {
	repo, mock := newMockRepo(t)

	mock.ExpectQuery("SELECT attendee_id, agenda_id").
		WithArgs("attendee@wso2.com", "1").
		WillReturnRows(sqlmock.NewRows([]string{"attendee_id", "agenda_id"}))

	got, err := repo.GetAgendaAttendee(context.Background(), "attendee@wso2.com", "1")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if got != nil {
		t.Errorf("expected nil, got %+v", got)
	}
}

func TestGetAgendaAttendeeCount(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"internalCount", "externalCount", "totalCount"}).AddRow(3, 2, 5)
	mock.ExpectQuery("SELECT").
		WithArgs("%@wso2.com%", "%@wso2.com%", 1).
		WillReturnRows(rows)

	got, err := repo.GetAgendaAttendeeCount(context.Background(), 1)
	if err != nil {
		t.Fatalf("GetAgendaAttendeeCount failed: %v", err)
	}
	want := AgendaAttendeeCount{InternalCount: 3, ExternalCount: 2, TotalCount: 5}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}
