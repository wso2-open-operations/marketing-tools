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
