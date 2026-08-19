// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import (
	"context"
	"database/sql"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestGetCurrentEvent(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"id", "name", "venue_name", "venue_address"}).
		AddRow("event-1", "WSO2Con Asia 2026", "Venue Hall", "Colombo, Sri Lanka")
	mock.ExpectQuery("SELECT id, name, venue_name, venue_address").WillReturnRows(rows)

	got, err := repo.GetCurrentEvent(context.Background())
	if err != nil {
		t.Fatalf("GetCurrentEvent failed: %v", err)
	}
	want := Event{ID: "event-1", Name: "WSO2Con Asia 2026", Location: "Venue Hall, Colombo, Sri Lanka"}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestGetCurrentEvent_PartialVenue(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"id", "name", "venue_name", "venue_address"}).
		AddRow("event-1", "WSO2Con Asia 2026", nil, nil)
	mock.ExpectQuery("SELECT id, name, venue_name, venue_address").WillReturnRows(rows)

	got, err := repo.GetCurrentEvent(context.Background())
	if err != nil {
		t.Fatalf("GetCurrentEvent failed: %v", err)
	}
	if got.Location != "" {
		t.Errorf("Location = %q, want empty", got.Location)
	}
}

func TestGetCurrentEvent_NoRows(t *testing.T) {
	repo, mock := newMockRepo(t)

	mock.ExpectQuery("SELECT id, name, venue_name, venue_address").WillReturnError(sql.ErrNoRows)

	_, err := repo.GetCurrentEvent(context.Background())
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}
