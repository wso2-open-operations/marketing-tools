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

	"wso2-coin-backend/internal/models"
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

// newConfiguredSessionFixture creates a conference_config with the given
// startDate (used by GetSessionPresenters' "latest start_date wins" scoping
// rule) plus a day and a scheduled session in it, and returns the ids needed
// to attach speakers or assert on results.
func newConfiguredSessionFixture(t *testing.T, ctx context.Context, startDate, dateStr string, title string) (sessionID, configID string) {
	t.Helper()

	err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date) VALUES ($1, $2) RETURNING id",
		"TDD Presenters Test Conference", startDate,
	).Scan(&configID)
	if err != nil {
		t.Fatalf("failed to insert test conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	var dayID string
	err = testDB.QueryRow(ctx,
		"INSERT INTO conference_days (config_id, day_index, date, start_minute) VALUES ($1, 0, $2, 480) RETURNING id",
		configID, dateStr,
	).Scan(&dayID)
	if err != nil {
		t.Fatalf("failed to insert test conference_day: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_days WHERE id = $1", dayID)
	})

	err = testDB.QueryRow(ctx,
		"INSERT INTO sessions (config_id, kind, title, day_id, slot_index) VALUES ($1, 'session', $2, $3, 0) RETURNING id",
		configID, title, dayID,
	).Scan(&sessionID)
	if err != nil {
		t.Fatalf("failed to insert test session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID)
	})

	return sessionID, configID
}

func attachSpeakerToSession(t *testing.T, ctx context.Context, sessionID, name string) {
	t.Helper()

	var speakerID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO speakers (name, title, bio, visible) VALUES ($1, '', '', true) RETURNING id",
		mustEncrypt(t, name),
	).Scan(&speakerID)
	if err != nil {
		t.Fatalf("failed to insert test speaker: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM speakers WHERE id = $1", speakerID)
	})

	_, err = testDB.Exec(ctx, "INSERT INTO session_speakers (session_id, speaker_id) VALUES ($1, $2)", sessionID, speakerID)
	if err != nil {
		t.Fatalf("failed to insert test session_speakers row: %v", err)
	}
}

func TestSessionRepo_GetSession_Scheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	fixture := newSessionFixture(t, ctx, "2026-05-23", 480)
	sessionID := fixture.insertScheduledSession(t, ctx, 12, 6)

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}

	if session.ID != sessionID {
		t.Errorf("ID = %q, want %q", session.ID, sessionID)
	}
	if session.Title != "TDD Test Session" {
		t.Errorf("Title = %q, want %q", session.Title, "TDD Test Session")
	}
	if session.DurationSlots != 6 {
		t.Errorf("DurationSlots = %d, want 6", session.DurationSlots)
	}
	if session.SlotIndex == nil || *session.SlotIndex != 12 {
		t.Errorf("SlotIndex = %v, want 12", session.SlotIndex)
	}

	wantStart := time.Date(2026, 5, 23, 9, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 5, 23, 9, 30, 0, 0, time.UTC)
	if session.StartTime == nil || !session.StartTime.Equal(wantStart) {
		t.Errorf("StartTime = %v, want %v", session.StartTime, wantStart)
	}
	if session.EndTime == nil || !session.EndTime.Equal(wantEnd) {
		t.Errorf("EndTime = %v, want %v", session.EndTime, wantEnd)
	}
}

func TestSessionRepo_GetSession_Unscheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	fixture := newSessionFixture(t, ctx, "2026-05-24", 480)
	sessionID := fixture.insertUnscheduledSession(t, ctx)

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if session.StartTime != nil {
		t.Errorf("StartTime = %v, want nil for an unscheduled session", session.StartTime)
	}
	if session.EndTime != nil {
		t.Errorf("EndTime = %v, want nil for an unscheduled session", session.EndTime)
	}
	if session.SlotIndex != nil {
		t.Errorf("SlotIndex = %v, want nil for an unscheduled session", session.SlotIndex)
	}
}

func TestSessionRepo_GetSession_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	_, err := repo.GetSession(ctx, newUUID())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetSession error = %v, want ErrNotFound", err)
	}
}

func TestSessionRepo_GetSessionPresenters_ScopesToLatestConfig(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	// Dates far outside any real or other-test data so this test's own
	// "latest config" ordering is deterministic regardless of what else
	// exists in this shared dev DB.
	oldSessionID, _ := newConfiguredSessionFixture(t, ctx, "2020-01-01", "2020-01-01", "Old Conference Session")
	latestSessionID, _ := newConfiguredSessionFixture(t, ctx, "2099-01-01", "2099-01-01", "Latest Conference Session")
	attachSpeakerToSession(t, ctx, oldSessionID, "Old Speaker")
	attachSpeakerToSession(t, ctx, latestSessionID, "Latest Speaker")

	presenters, err := repo.GetSessionPresenters(ctx)
	if err != nil {
		t.Fatalf("GetSessionPresenters returned error: %v", err)
	}

	ids := make(map[string]models.SessionPresenters)
	for _, p := range presenters {
		ids[p.ID] = p
	}
	if _, ok := ids[oldSessionID]; ok {
		t.Errorf("expected session %s from the older config to be excluded", oldSessionID)
	}
	got, ok := ids[latestSessionID]
	if !ok {
		t.Fatalf("expected session %s from the latest config to be present", latestSessionID)
	}
	if got.Name != "Latest Conference Session" {
		t.Errorf("Name = %q, want %q", got.Name, "Latest Conference Session")
	}
	if len(got.Presenters) != 1 || got.Presenters[0] != "Latest Speaker" {
		t.Errorf("Presenters = %v, want [\"Latest Speaker\"] (decrypted)", got.Presenters)
	}
}

func TestSessionRepo_GetSessionPresenters_ExcludesSessionsWithNoSpeakers(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	withSpeaker, _ := newConfiguredSessionFixture(t, ctx, "2099-02-01", "2099-02-01", "Session With Speaker")
	withoutSpeaker, _ := newConfiguredSessionFixture(t, ctx, "2099-02-01", "2099-02-01", "Session Without Speaker")
	attachSpeakerToSession(t, ctx, withSpeaker, "Some Speaker")

	presenters, err := repo.GetSessionPresenters(ctx)
	if err != nil {
		t.Fatalf("GetSessionPresenters returned error: %v", err)
	}

	ids := make(map[string]bool)
	for _, p := range presenters {
		ids[p.ID] = true
	}
	if !ids[withSpeaker] {
		t.Errorf("expected session %s (has a speaker) to be present", withSpeaker)
	}
	if ids[withoutSpeaker] {
		t.Errorf("expected session %s (no speakers) to be excluded", withoutSpeaker)
	}
}

func TestSessionRepo_GetTimeWindow_Scheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

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
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	randomID := newUUID()
	_, _, err := repo.GetTimeWindow(ctx, randomID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", randomID, err)
	}
}

func TestSessionRepo_GetTimeWindow_Unscheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey)

	fixture := newSessionFixture(t, ctx, "2026-05-22", 480)
	sessionID := fixture.insertUnscheduledSession(t, ctx)

	_, _, err := repo.GetTimeWindow(ctx, sessionID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", sessionID, err)
	}
}
