// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"attendee-registration/internal/crypto"

	"github.com/DATA-DOG/go-sqlmock"
)

func init() {
	// Encrypt/Decrypt require a key; every test in this package that
	// touches attendee_id goes through this same key.
	if err := crypto.Init(bytes.Repeat([]byte("k"), 32)); err != nil {
		panic(err)
	}
}

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

	rows := sqlmock.NewRows([]string{"id", "title", "date"}).
		AddRow("session-1", "Day 1", time.Date(2026, 7, 29, 0, 0, 0, 0, time.UTC)).
		AddRow("session-2", "Day 2", time.Date(2026, 7, 30, 0, 0, 0, 0, time.UTC))
	mock.ExpectQuery("SELECT s.id, s.title, d.date").WithArgs("event-1").WillReturnRows(rows)

	got, err := repo.GetAgendas(context.Background(), "event-1")
	if err != nil {
		t.Fatalf("GetAgendas failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 agendas, got %d", len(got))
	}
	if got[0].Name != "Day 1" || got[0].Date != "2026-07-29" {
		t.Errorf("unexpected agenda[0]: %+v", got[0])
	}
	if got[1].Name != "Day 2" || got[1].Date != "2026-07-30" {
		t.Errorf("unexpected agenda[1]: %+v", got[1])
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestGetAgendas_Empty(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"id", "title", "date"})
	mock.ExpectQuery("SELECT s.id, s.title, d.date").WithArgs("event-1").WillReturnRows(rows)

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

	// attendee_id is encrypted before insert, so the ciphertext arg is
	// non-deterministic (see internal/crypto) -- only the session id and
	// updated-by are asserted exactly.
	mock.ExpectExec("INSERT INTO attendee_registration").
		WithArgs(sqlmock.AnyArg(), "1", "admin@wso2.com").
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

	mock.ExpectExec("INSERT INTO attendee_registration").
		WithArgs(sqlmock.AnyArg(), "1", "admin@wso2.com").
		WillReturnError(errors.New("duplicate entry"))

	if err := repo.InsertAgendaAttendee(context.Background(), "attendee@wso2.com", "1", "admin@wso2.com"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestGetAgendaAttendee_Found(t *testing.T) {
	repo, mock := newMockRepo(t)

	encrypted, err := crypto.Encrypt("attendee@wso2.com")
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}

	rows := sqlmock.NewRows([]string{"attendee_id"}).AddRow(encrypted)
	mock.ExpectQuery("SELECT attendee_id FROM attendee_registration").WithArgs("1").WillReturnRows(rows)

	got, err := repo.GetAgendaAttendee(context.Background(), "attendee@wso2.com", "1")
	if err != nil {
		t.Fatalf("GetAgendaAttendee failed: %v", err)
	}
	if got == nil {
		t.Fatal("expected a result, got nil")
	}
	if got.AttendeeID != "attendee@wso2.com" || got.AgendaID != "1" {
		t.Errorf("unexpected result: %+v", got)
	}
}

func TestGetAgendaAttendee_NotFound(t *testing.T) {
	repo, mock := newMockRepo(t)

	mock.ExpectQuery("SELECT attendee_id FROM attendee_registration").
		WithArgs("1").
		WillReturnRows(sqlmock.NewRows([]string{"attendee_id"}))

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

	internalEmails := []string{"a1@wso2.com", "a2@wso2.com", "a3@wso2.com"}
	externalEmails := []string{"e1@example.com", "e2@example.com"}

	rows := sqlmock.NewRows([]string{"attendee_id"})
	for _, email := range internalEmails {
		enc, err := crypto.Encrypt(email)
		if err != nil {
			t.Fatalf("failed to encrypt fixture email: %v", err)
		}
		rows.AddRow(enc)
	}
	for _, email := range externalEmails {
		enc, err := crypto.Encrypt(email)
		if err != nil {
			t.Fatalf("failed to encrypt fixture email: %v", err)
		}
		rows.AddRow(enc)
	}

	mock.ExpectQuery("SELECT attendee_id FROM attendee_registration").WithArgs("1").WillReturnRows(rows)

	got, err := repo.GetAgendaAttendeeCount(context.Background(), "1")
	if err != nil {
		t.Fatalf("GetAgendaAttendeeCount failed: %v", err)
	}
	want := AgendaAttendeeCount{InternalCount: 3, ExternalCount: 2, TotalCount: 5}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}
