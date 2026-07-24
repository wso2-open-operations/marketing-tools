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
	"testing"
	"time"
)

// eventFixture inserts an isolated conference_config row for a single test,
// and registers cleanup that deletes only that row.
type eventFixture struct {
	configID string
}

func newEventFixture(t *testing.T, ctx context.Context, name, startDate string) *eventFixture {
	t.Helper()

	var configID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date) VALUES ($1, $2) RETURNING id",
		name, startDate,
	).Scan(&configID)
	if err != nil {
		t.Fatalf("failed to insert test conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	return &eventFixture{configID: configID}
}

func (f *eventFixture) insertDay(t *testing.T, ctx context.Context, dayIndex int, dateStr, label string, startMinute int) string {
	t.Helper()
	var dayID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO conference_days (config_id, day_index, date, label, start_minute) VALUES ($1, $2, $3, $4, $5) RETURNING id",
		f.configID, dayIndex, dateStr, label, startMinute,
	).Scan(&dayID)
	if err != nil {
		t.Fatalf("failed to insert test conference_day: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_days WHERE id = $1", dayID)
	})
	return dayID
}

func (f *eventFixture) insertSession(t *testing.T, ctx context.Context, dayID string, slotIndex, durationSlots int, title string) string {
	t.Helper()
	var sessionID string
	err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index)
		 VALUES ($1, 'session', $2, $3, $4, $5) RETURNING id`,
		f.configID, title, durationSlots, dayID, slotIndex,
	).Scan(&sessionID)
	if err != nil {
		t.Fatalf("failed to insert test session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID)
	})
	return sessionID
}

func TestEventRepo_GetEvents_OrdersByStartDateDescendingWithLatestCurrent(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	// Dates far outside any real or other-test data so ordering is
	// deterministic regardless of what else exists in this shared dev DB.
	older := newEventFixture(t, ctx, "TDD Older Conference", "2020-01-01")
	latest := newEventFixture(t, ctx, "TDD Latest Conference", "2099-01-01")

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}

	byID := make(map[string]bool)
	for _, e := range events {
		byID[e.ID] = e.IsCurrent
	}

	latestCurrent, ok := byID[latest.configID]
	if !ok {
		t.Fatalf("expected latest config %s to be present", latest.configID)
	}
	if !latestCurrent {
		t.Errorf("expected latest config %s to have IsCurrent = true", latest.configID)
	}

	olderCurrent, ok := byID[older.configID]
	if !ok {
		t.Fatalf("expected older config %s to be present", older.configID)
	}
	if olderCurrent {
		t.Errorf("expected older config %s to have IsCurrent = false", older.configID)
	}
}

func TestEventRepo_GetEvents_ReadsTimezoneAndVenueColumns(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	var configID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO conference_config (name, start_date, timezone, venue_name, venue_address)
		 VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		"TDD Venue Conference", "2099-12-01", "Asia/Colombo", "BMICH", "Colombo",
	).Scan(&configID); err != nil {
		t.Fatalf("failed to insert config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}
	var found bool
	for _, e := range events {
		if e.ID != configID {
			continue
		}
		found = true
		if e.Timezone != "Asia/Colombo" {
			t.Errorf("Timezone = %q, want Asia/Colombo (from the column)", e.Timezone)
		}
		if e.VenueName != "BMICH" {
			t.Errorf("VenueName = %q, want BMICH", e.VenueName)
		}
		if e.VenueAddress != "Colombo" {
			t.Errorf("VenueAddress = %q, want Colombo", e.VenueAddress)
		}
	}
	if !found {
		t.Fatalf("expected config %s in GetEvents result", configID)
	}
}

func TestEventRepo_GetEventAgendas_ResolvesCurrentToLatestStartDate(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	older := newEventFixture(t, ctx, "TDD Older Conference", "2020-02-01")
	older.insertDay(t, ctx, 0, "2020-02-01", "Day 1", 480)
	latest := newEventFixture(t, ctx, "TDD Latest Conference", "2099-02-01")
	latestDayID := latest.insertDay(t, ctx, 0, "2099-02-01", "Day 1", 480)

	agendas, err := repo.GetEventAgendas(ctx, "current")
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}

	for _, a := range agendas {
		if a.EventID == older.configID {
			t.Errorf("expected day %s from the older config to be excluded from 'current'", a.ID)
		}
	}
	found := false
	for _, a := range agendas {
		if a.ID == latestDayID {
			found = true
		}
	}
	if !found {
		t.Errorf("expected day %s from the latest config to be present", latestDayID)
	}
}

func TestEventRepo_GetEventAgendas_ByExplicitEventID(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	// Even though this config isn't the latest by start_date, requesting it
	// by explicit id must still return its days.
	notCurrent := newEventFixture(t, ctx, "TDD Not Current Conference", "2010-01-01")
	current := newEventFixture(t, ctx, "TDD Current Conference", "2100-01-01")
	current.insertDay(t, ctx, 0, "2100-01-01", "Day 1", 480)

	day1 := notCurrent.insertDay(t, ctx, 0, "2010-01-01", "Day 1", 480)
	day2 := notCurrent.insertDay(t, ctx, 1, "2010-01-02", "Day 2", 480)

	agendas, err := repo.GetEventAgendas(ctx, notCurrent.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}

	if len(agendas) != 2 {
		t.Fatalf("len(agendas) = %d, want 2", len(agendas))
	}
	if agendas[0].ID != day1 || agendas[1].ID != day2 {
		t.Errorf("agendas = %+v, want day_index order [%s, %s]", agendas, day1, day2)
	}
	for _, a := range agendas {
		if a.EventID != notCurrent.configID {
			t.Errorf("EventID = %q, want %q", a.EventID, notCurrent.configID)
		}
	}
}

func TestEventRepo_GetEventAgendas_UnknownEventIDReturnsEmptyNoError(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	agendas, err := repo.GetEventAgendas(ctx, newUUID())
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 0 {
		t.Errorf("agendas = %+v, want empty", agendas)
	}
}

func TestEventRepo_GetEventAgendas_DayWithZeroSessionsHasEmptySessionsArray(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)

	fixture := newEventFixture(t, ctx, "TDD Empty Day Conference", "2200-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2200-01-01", "Day 1", 480)

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 {
		t.Fatalf("len(agendas) = %d, want 1", len(agendas))
	}
	if agendas[0].ID != dayID {
		t.Errorf("ID = %q, want %q", agendas[0].ID, dayID)
	}
	if agendas[0].Sessions == nil || len(agendas[0].Sessions) != 0 {
		t.Errorf("Sessions = %v, want a non-nil empty slice", agendas[0].Sessions)
	}
}

func TestEventRepo_GetEventAgendas_NestedSessionTimeWindowMatchesGetSession(t *testing.T) {
	ctx := context.Background()
	eventRepo := NewEventRepo(testDB, 5, time.UTC, "UTC", speakerTestKey)
	sessionRepo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	fixture := newEventFixture(t, ctx, "TDD Window Match Conference", "2300-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2300-01-01", "Day 1", 480)
	sessionID := fixture.insertSession(t, ctx, dayID, 12, 6, "TDD Window Match Session")

	agendas, err := eventRepo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 1 {
		t.Fatalf("agendas = %+v, want one day with one session", agendas)
	}
	nested := agendas[0].Sessions[0]

	want, err := sessionRepo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}

	if nested.StartTime == nil || want.StartTime == nil || !nested.StartTime.Equal(*want.StartTime) {
		t.Errorf("nested StartTime = %v, want %v", nested.StartTime, want.StartTime)
	}
	if nested.EndTime == nil || want.EndTime == nil || !nested.EndTime.Equal(*want.EndTime) {
		t.Errorf("nested EndTime = %v, want %v", nested.EndTime, want.EndTime)
	}
}
