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

//go:build integration

package repository

import (
	"context"
	"errors"
	"testing"
	"time"
)

// sessionFixture inserts an isolated conference_config -> conference_days ->
// sessions chain for a single test, and registers cleanup that deletes only
// those specific rows by id. It never touches unrelated rows in these shared
// tables.
type sessionFixture struct {
	configID string
	dayID    string
}

func newSessionFixture(t *testing.T, ctx context.Context, dateStr string, startMinute int) *sessionFixture {
	t.Helper()

	var configID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date) VALUES ($1, $2) RETURNING id",
		"TDD Test Conference", dateStr,
	).Scan(&configID)
	if err != nil {
		t.Fatalf("failed to insert test conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	var dayID string
	err = testDB.QueryRow(ctx,
		"INSERT INTO conference_days (config_id, day_index, date, start_minute) VALUES ($1, 0, $2, $3) RETURNING id",
		configID, dateStr, startMinute,
	).Scan(&dayID)
	if err != nil {
		t.Fatalf("failed to insert test conference_day: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_days WHERE id = $1", dayID)
	})

	return &sessionFixture{configID: configID, dayID: dayID}
}

func (f *sessionFixture) insertScheduledSession(t *testing.T, ctx context.Context, slotIndex, durationSlots int) string {
	t.Helper()
	var sessionID string
	err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index)
		 VALUES ($1, 'session', 'TDD Test Session', $2, $3, $4) RETURNING id`,
		f.configID, durationSlots, f.dayID, slotIndex,
	).Scan(&sessionID)
	if err != nil {
		t.Fatalf("failed to insert test session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID)
	})
	return sessionID
}

func (f *sessionFixture) insertUnscheduledSession(t *testing.T, ctx context.Context) string {
	t.Helper()
	var sessionID string
	err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index)
		 VALUES ($1, 'session', 'TDD Test Unscheduled Session', 1, NULL, NULL) RETURNING id`,
		f.configID,
	).Scan(&sessionID)
	if err != nil {
		t.Fatalf("failed to insert test unscheduled session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID)
	})
	return sessionID
}

func TestSessionRepo_GetTimeWindow_Scheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5)

	fixture := newSessionFixture(t, ctx, "2026-05-21", 480)
	sessionID := fixture.insertScheduledSession(t, ctx, 12, 6)

	start, end, err := repo.GetTimeWindow(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetTimeWindow returned error: %v", err)
	}

	wantStart := time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)

	if !start.Equal(wantStart) {
		t.Errorf("start = %v, want %v", start, wantStart)
	}
	if !end.Equal(wantEnd) {
		t.Errorf("end = %v, want %v", end, wantEnd)
	}
}

func TestSessionRepo_GetTimeWindow_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5)

	randomID := newUUID()
	_, _, err := repo.GetTimeWindow(ctx, randomID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", randomID, err)
	}
}

func TestSessionRepo_GetTimeWindow_Unscheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5)

	fixture := newSessionFixture(t, ctx, "2026-05-22", 480)
	sessionID := fixture.insertUnscheduledSession(t, ctx)

	_, _, err := repo.GetTimeWindow(ctx, sessionID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", sessionID, err)
	}
}
