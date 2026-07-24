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

// insertSpeakerReturningID inserts a speaker with the given visibility and
// returns its id, for tests that need the id (e.g. to set an overlay row).
func insertSpeakerReturningID(t *testing.T, ctx context.Context, name string, visible bool) string {
	t.Helper()
	var speakerID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO speakers (name, title, bio, visible) VALUES ($1, '', '', $2) RETURNING id",
		mustEncrypt(t, name), visible,
	).Scan(&speakerID)
	if err != nil {
		t.Fatalf("failed to insert test speaker: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM speakers WHERE id = $1", speakerID)
	})
	return speakerID
}

func linkSpeaker(t *testing.T, ctx context.Context, sessionID, speakerID string) {
	t.Helper()
	if _, err := testDB.Exec(ctx,
		"INSERT INTO session_speakers (session_id, speaker_id) VALUES ($1, $2)", sessionID, speakerID,
	); err != nil {
		t.Fatalf("failed to link speaker %s to session %s: %v", speakerID, sessionID, err)
	}
}

func attachHiddenSpeakerToSession(t *testing.T, ctx context.Context, sessionID, name string) {
	t.Helper()

	var speakerID string
	err := testDB.QueryRow(ctx,
		"INSERT INTO speakers (name, title, bio, visible) VALUES ($1, '', '', false) RETURNING id",
		mustEncrypt(t, name),
	).Scan(&speakerID)
	if err != nil {
		t.Fatalf("failed to insert hidden test speaker: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM speakers WHERE id = $1", speakerID)
	})

	_, err = testDB.Exec(ctx, "INSERT INTO session_speakers (session_id, speaker_id) VALUES ($1, $2)", sessionID, speakerID)
	if err != nil {
		t.Fatalf("failed to insert hidden test session_speakers row: %v", err)
	}
}

func TestSessionRepo_GetSession_Scheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

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

func TestSessionRepo_GetSession_EmbedsSpeakersSortedByName(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	sessionID, _ := newConfiguredSessionFixture(t, ctx, "2099-05-01", "2099-05-01", "Embed Test Session")
	// Attach out of alphabetical order to prove the repo sorts by name.
	attachSpeakerToSession(t, ctx, sessionID, "Zara Zed")
	attachSpeakerToSession(t, ctx, sessionID, "Ada Lovelace")

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if len(session.Speakers) != 2 {
		t.Fatalf("Speakers = %+v, want 2", session.Speakers)
	}
	if session.Speakers[0].Name != "Ada Lovelace" || session.Speakers[1].Name != "Zara Zed" {
		t.Errorf("speaker order = [%q, %q], want [Ada Lovelace, Zara Zed] (sorted, decrypted)",
			session.Speakers[0].Name, session.Speakers[1].Name)
	}
	if session.Speakers[0].ID == "" {
		t.Errorf("expected embedded speaker to carry an id")
	}
}

func TestSessionRepo_GetSession_NoSpeakersIsEmptyNotNil(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	fixture := newSessionFixture(t, ctx, "2099-06-01", 480)
	sessionID := fixture.insertScheduledSession(t, ctx, 0, 6)

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if session.Speakers == nil {
		t.Errorf("Speakers = nil, want a non-nil empty slice (JSON [] not null)")
	}
	if len(session.Speakers) != 0 {
		t.Errorf("Speakers = %+v, want empty", session.Speakers)
	}
}

func TestSessionRepo_GetSession_ExcludesHiddenSpeakers(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	sessionID, _ := newConfiguredSessionFixture(t, ctx, "2099-07-01", "2099-07-01", "Hidden Speaker Session")
	attachSpeakerToSession(t, ctx, sessionID, "Visible Vera")
	attachHiddenSpeakerToSession(t, ctx, sessionID, "Hidden Hank")

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if len(session.Speakers) != 1 || session.Speakers[0].Name != "Visible Vera" {
		t.Errorf("Speakers = %+v, want only the visible speaker", session.Speakers)
	}
}

func TestSessionRepo_DayIDsForSessions(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	fixture := newSessionFixture(t, ctx, "2099-10-01", 480)
	scheduled := fixture.insertScheduledSession(t, ctx, 0, 6) // has day_id
	unscheduled := fixture.insertUnscheduledSession(t, ctx)   // day_id NULL

	got, err := repo.DayIDsForSessions(ctx, []string{scheduled, unscheduled, newUUID(), "not-a-uuid"})
	if err != nil {
		t.Fatalf("DayIDsForSessions returned error: %v", err)
	}
	if got[scheduled] != fixture.dayID {
		t.Errorf("dayId for scheduled session = %q, want %q", got[scheduled], fixture.dayID)
	}
	if _, ok := got[unscheduled]; ok {
		t.Errorf("unscheduled session should be absent (day_id NULL), got %q", got[unscheduled])
	}
	if len(got) != 1 {
		t.Errorf("expected exactly 1 resolved mapping, got %d (%v)", len(got), got)
	}
}

func TestSessionRepo_GetSession_ModeratorComesFromOverlay(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	sessionID, _ := newConfiguredSessionFixture(t, ctx, "2099-08-01", "2099-08-01", "Moderator Test Session")

	modID := insertSpeakerReturningID(t, ctx, "Mod Erator", true)
	plainID := insertSpeakerReturningID(t, ctx, "Plain Speaker", true)
	linkSpeaker(t, ctx, sessionID, modID)
	linkSpeaker(t, ctx, sessionID, plainID)

	// Only modID is designated a moderator via the owned overlay.
	if _, err := testDB.Exec(ctx,
		"INSERT INTO presentation_overlay (session_id, speaker_id, is_moderator) VALUES ($1, $2, true)",
		sessionID, modID,
	); err != nil {
		t.Fatalf("failed to insert overlay row: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM presentation_overlay WHERE session_id = $1", sessionID)
	})

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	got := make(map[string]bool)
	for _, sp := range session.Speakers {
		got[sp.ID] = sp.IsModerator
	}
	if !got[modID] {
		t.Errorf("expected speaker %s to be a moderator (overlay row present)", modID)
	}
	if got[plainID] {
		t.Errorf("expected speaker %s NOT to be a moderator (no overlay row)", plainID)
	}
}

func TestSessionRepo_GetSession_ResolvesTrackColorAndRoomName(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	fixture := newSessionFixture(t, ctx, "2099-09-01", 480)

	var trackID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO tracks (day_id, color, position) VALUES ($1, '#123abc', 0) RETURNING id",
		fixture.dayID,
	).Scan(&trackID); err != nil {
		t.Fatalf("failed to insert track: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM tracks WHERE id = $1", trackID) })

	var roomID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO rooms (config_id, name, capacity) VALUES ($1, 'Blue Hall', 100) RETURNING id",
		fixture.configID,
	).Scan(&roomID); err != nil {
		t.Fatalf("failed to insert room: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM rooms WHERE id = $1", roomID) })

	var sessionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index, track_id, room_id)
		 VALUES ($1, 'session', 'Coloured Session', 6, $2, 0, $3, $4) RETURNING id`,
		fixture.configID, fixture.dayID, trackID, roomID,
	).Scan(&sessionID); err != nil {
		t.Fatalf("failed to insert session: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if session.TrackColor != "#123abc" {
		t.Errorf("TrackColor = %q, want %q (from tracks.color)", session.TrackColor, "#123abc")
	}
	if session.RoomName != "Blue Hall" {
		t.Errorf("RoomName = %q, want %q (from rooms.name)", session.RoomName, "Blue Hall")
	}
}

func TestSessionRepo_GetSession_Unscheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

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
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	_, err := repo.GetSession(ctx, newUUID())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetSession error = %v, want ErrNotFound", err)
	}
}

func TestSessionRepo_GetCurrentSessions_ScopesToLatestConfig(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	// Dates far outside any real or other-test data so this test's own
	// "latest config" ordering is deterministic regardless of what else
	// exists in this shared dev DB.
	oldSessionID, _ := newConfiguredSessionFixture(t, ctx, "2020-01-01", "2020-01-01", "Old Conference Session")
	latestSessionID, _ := newConfiguredSessionFixture(t, ctx, "2099-01-01", "2099-01-01", "Latest Conference Session")

	sessions, err := repo.GetCurrentSessions(ctx)
	if err != nil {
		t.Fatalf("GetCurrentSessions returned error: %v", err)
	}

	byID := make(map[string]models.Session)
	for _, s := range sessions {
		byID[s.ID] = s
	}
	if _, ok := byID[oldSessionID]; ok {
		t.Errorf("expected session %s from the older config to be excluded", oldSessionID)
	}
	got, ok := byID[latestSessionID]
	if !ok {
		t.Fatalf("expected session %s from the latest config to be present", latestSessionID)
	}
	if got.Title != "Latest Conference Session" {
		t.Errorf("Title = %q, want %q", got.Title, "Latest Conference Session")
	}
	if got.StartTime == nil {
		t.Errorf("expected a scheduled session to carry a StartTime")
	}
}

// The reshaped GET /sessions/current no longer inner-joins speakers, so a
// session with no speakers (a break, registration) is now included rather
// than silently dropped -- the inverse of the old presenters behavior.
func TestSessionRepo_GetCurrentSessions_IncludesSessionsWithNoSpeakers(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	// Both sessions must live in the SAME (latest) config: GetCurrentSessions
	// scopes to one config, so a second fixture would create a rival config.
	withSpeaker, configID := newConfiguredSessionFixture(t, ctx, "2099-03-01", "2099-03-01", "Session With Speaker")
	attachSpeakerToSession(t, ctx, withSpeaker, "Some Speaker")

	var withoutSpeaker string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO sessions (config_id, kind, title, day_id, slot_index) VALUES ($1, 'break', 'Coffee Break', NULL, NULL) RETURNING id",
		configID,
	).Scan(&withoutSpeaker); err != nil {
		t.Fatalf("failed to insert speaker-less session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", withoutSpeaker)
	})

	sessions, err := repo.GetCurrentSessions(ctx)
	if err != nil {
		t.Fatalf("GetCurrentSessions returned error: %v", err)
	}

	ids := make(map[string]bool)
	for _, s := range sessions {
		ids[s.ID] = true
	}
	if !ids[withSpeaker] {
		t.Errorf("expected session %s (has a speaker) to be present", withSpeaker)
	}
	if !ids[withoutSpeaker] {
		t.Errorf("expected session %s (no speakers) to be INCLUDED now, was excluded", withoutSpeaker)
	}
}

// insertSessionInConfigTZ creates a conference_config with the given IANA
// timezone column, a day (start_minute 480 = 08:00) and one scheduled session
// at slot 0 for 6 slots, and returns the session id. Used to prove
// conference_config.timezone is the source of truth for anchoring.
func insertSessionInConfigTZ(t *testing.T, ctx context.Context, tz, dateStr string) string {
	t.Helper()
	var configID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date, timezone) VALUES ($1, $2, $3) RETURNING id",
		"TDD TZ Conference", dateStr, tz,
	).Scan(&configID); err != nil {
		t.Fatalf("failed to insert config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	var dayID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO conference_days (config_id, day_index, date, start_minute) VALUES ($1, 0, $2, 480) RETURNING id",
		configID, dateStr,
	).Scan(&dayID); err != nil {
		t.Fatalf("failed to insert day: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM conference_days WHERE id = $1", dayID) })

	var sessionID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index) VALUES ($1, 'session', 'TZ Session', 6, $2, 0) RETURNING id",
		configID, dayID,
	).Scan(&sessionID); err != nil {
		t.Fatalf("failed to insert session: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })
	return sessionID
}

// conference_config.timezone is the source of truth: a session in an
// Asia/Colombo config resolves to 08:00 +05:30 even though the repo's env
// fallback loc is UTC.
func TestSessionRepo_GetSession_AnchorsToConfigTimezoneColumn(t *testing.T) {
	colombo, err := time.LoadLocation("Asia/Colombo")
	if err != nil {
		t.Skipf("tzdata for Asia/Colombo unavailable: %v", err)
	}
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC) // env fallback UTC on purpose

	sessionID := insertSessionInConfigTZ(t, ctx, "Asia/Colombo", "2026-07-01")

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if session.StartTime == nil {
		t.Fatal("expected a StartTime")
	}
	wantStart := time.Date(2026, 7, 1, 8, 0, 0, 0, colombo)
	if !session.StartTime.Equal(wantStart) {
		t.Errorf("StartTime instant = %v, want %v", session.StartTime, wantStart)
	}
	if _, offset := session.StartTime.Zone(); offset != 19800 {
		t.Errorf("StartTime zone offset = %d, want 19800 (+05:30)", offset)
	}
}

// The column wins over the env fallback in the other direction too: a config
// explicitly set to UTC yields UTC even when the repo's env loc is non-UTC.
func TestSessionRepo_GetSession_ConfigTimezoneUTCWinsOverEnvLoc(t *testing.T) {
	colombo, err := time.LoadLocation("Asia/Colombo")
	if err != nil {
		t.Skipf("tzdata for Asia/Colombo unavailable: %v", err)
	}
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, colombo) // env fallback is Colombo

	sessionID := insertSessionInConfigTZ(t, ctx, "UTC", "2026-07-02")

	session, err := repo.GetSession(ctx, sessionID)
	if err != nil {
		t.Fatalf("GetSession returned error: %v", err)
	}
	if session.StartTime == nil {
		t.Fatal("expected a StartTime")
	}
	if _, offset := session.StartTime.Zone(); offset != 0 {
		t.Errorf("StartTime zone offset = %d, want 0 (UTC column wins over the Colombo env fallback)", offset)
	}
}

func TestSessionRepo_GetTimeWindow_Scheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

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
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	randomID := newUUID()
	_, _, err := repo.GetTimeWindow(ctx, randomID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", randomID, err)
	}
}

func TestSessionRepo_GetTimeWindow_Unscheduled(t *testing.T) {
	ctx := context.Background()
	repo := NewSessionRepo(testDB, 5, speakerTestKey, time.UTC)

	fixture := newSessionFixture(t, ctx, "2026-05-22", 480)
	sessionID := fixture.insertUnscheduledSession(t, ctx)

	_, _, err := repo.GetTimeWindow(ctx, sessionID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetTimeWindow(%q) error = %v, want ErrNotFound", sessionID, err)
	}
}
