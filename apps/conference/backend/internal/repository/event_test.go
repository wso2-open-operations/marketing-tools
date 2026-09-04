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
		// end_minute is explicit: the live CHECK is start_minute < end_minute
		// <= 1440 and the column DEFAULTs to 17, which fails for any real
		// start_minute. 1020 = 17:00, an 08:00-17:00 conference day.
		"INSERT INTO conference_days (config_id, day_index, date, label, start_minute, end_minute) VALUES ($1, $2, $3, $4, $5, 1020) RETURNING id",
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
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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

func TestEventRepo_GetCurrentEvent_ReturnsLatestStartDate(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	newEventFixture(t, ctx, "TDD Current Older", "2020-02-02")
	latest := newEventFixture(t, ctx, "TDD Current Latest", "2099-02-02")

	event, err := repo.GetCurrentEvent(ctx)
	if err != nil {
		t.Fatalf("GetCurrentEvent returned error: %v", err)
	}
	if event.ID != latest.configID {
		t.Errorf("GetCurrentEvent returned %s, want the latest-start_date config %s", event.ID, latest.configID)
	}
	if !event.IsCurrent {
		t.Error("GetCurrentEvent must always report IsCurrent = true on the row it returns")
	}
}

// The contract GetCurrentEvent's doc comment claims is that it resolves
// "current" the same way GetEvents does. On tied start_dates a bare start_date
// sort leaves that to the planner, independently per statement, so this asserts
// the two agree rather than asserting either one in isolation.
func TestEventRepo_GetCurrentEvent_AgreesWithGetEventsOnTiedStartDates(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	const tiedDate = "2099-03-03"
	first := newEventFixture(t, ctx, "TDD Tied A", tiedDate)
	second := newEventFixture(t, ctx, "TDD Tied B", tiedDate)

	current, err := repo.GetCurrentEvent(ctx)
	if err != nil {
		t.Fatalf("GetCurrentEvent returned error: %v", err)
	}

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}
	var flagged string
	for _, e := range events {
		if e.IsCurrent {
			flagged = e.ID
			break
		}
	}

	if current.ID != flagged {
		t.Errorf("GetCurrentEvent chose %s but GetEvents flagged %s as current; the two tied configs are %s and %s",
			current.ID, flagged, first.configID, second.configID)
	}

	// Also pin down the direction, so the shared rule names a specific row and
	// not merely a consistent one: highest id wins a tie. Postgres decides which
	// that is -- comparing the ids in Go would assume a text-shaped id and give
	// the wrong answer for, say, a numeric one.
	var expected string
	if err := testDB.QueryRow(ctx,
		"SELECT id FROM conference_config WHERE id IN ($1, $2) ORDER BY id DESC LIMIT 1",
		first.configID, second.configID,
	).Scan(&expected); err != nil {
		t.Fatalf("resolving the expected tie winner: %v", err)
	}
	if current.ID != expected {
		t.Errorf("GetCurrentEvent chose %s, want %s (highest id among tied start_dates)", current.ID, expected)
	}
}

// StartDate comes straight from the column; EndDate has no column behind it and
// is the last conference_days.date, so a conference's span is whatever days the
// content team actually entered.
func TestEventRepo_GetEvents_DateBoundsSpanTheEnteredDays(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	f := newEventFixture(t, ctx, "TDD Dated Conference", "2099-04-01")
	// Inserted out of order on purpose: the end is the greatest date, not the
	// last row or the highest day_index.
	f.insertDay(t, ctx, 2, "2099-04-03", "Day 3", 480)
	f.insertDay(t, ctx, 0, "2099-04-01", "Day 1", 480)
	f.insertDay(t, ctx, 1, "2099-04-02", "Day 2", 480)

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}

	var got *struct{ start, end string }
	for _, e := range events {
		if e.ID == f.configID {
			got = &struct{ start, end string }{e.StartDate, e.EndDate}
			break
		}
	}
	if got == nil {
		t.Fatalf("config %s missing from GetEvents", f.configID)
	}
	if got.start != "2099-04-01" {
		t.Errorf("startDate = %q, want 2099-04-01", got.start)
	}
	if got.end != "2099-04-03" {
		t.Errorf("endDate = %q, want 2099-04-03 (the last conference_days.date)", got.end)
	}
}

// A conference whose days are not entered yet still has to report both bounds --
// GREATEST skipping the NULL from the day subquery is what makes that hold, and
// it is the reason the endDate key carries no omitempty.
func TestEventRepo_GetEvents_EndDateFallsBackToStartDateWithoutDays(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	f := newEventFixture(t, ctx, "TDD Dayless Conference", "2099-05-05")

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}
	for _, e := range events {
		if e.ID != f.configID {
			continue
		}
		if e.StartDate != "2099-05-05" || e.EndDate != "2099-05-05" {
			t.Errorf("bounds = %q / %q, want 2099-05-05 twice for a config with no days", e.StartDate, e.EndDate)
		}
		return
	}
	t.Fatalf("config %s missing from GetEvents", f.configID)
}

// GET /events and GET /events/current serve the same struct from two separate
// statements, so a client reading the bounds off either must see the same two
// dates. This compares the row GetCurrentEvent actually picked rather than
// assuming the fixture won -- other rows in this shared dev DB may outrank it.
func TestEventRepo_GetCurrentEvent_ReportsTheSameDateBoundsAsGetEvents(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	f := newEventFixture(t, ctx, "TDD Current Dated", "2099-06-01")
	f.insertDay(t, ctx, 0, "2099-06-01", "Day 1", 480)
	f.insertDay(t, ctx, 1, "2099-06-02", "Day 2", 480)

	current, err := repo.GetCurrentEvent(ctx)
	if err != nil {
		t.Fatalf("GetCurrentEvent returned error: %v", err)
	}
	if current.StartDate == "" || current.EndDate == "" {
		t.Errorf("bounds = %q / %q, want both populated", current.StartDate, current.EndDate)
	}

	events, err := repo.GetEvents(ctx)
	if err != nil {
		t.Fatalf("GetEvents returned error: %v", err)
	}
	for _, e := range events {
		if e.ID != current.ID {
			continue
		}
		if e.StartDate != current.StartDate || e.EndDate != current.EndDate {
			t.Errorf("GetEvents reports %q / %q for %s but GetCurrentEvent reports %q / %q",
				e.StartDate, e.EndDate, e.ID, current.StartDate, current.EndDate)
		}
		return
	}
	t.Fatalf("the current config %s is missing from GetEvents", current.ID)
}

func TestEventRepo_GetEvents_ReadsTimezoneAndVenueColumns(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

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
	eventRepo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")
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

// 16 of 18 keynotes and every break sit on no track, so a colour read off
// tracks alone leaves them colourless -- which is exactly why upstream 027 put
// the token on the room and made the track the fallback. A trackless but roomed
// session must come back with its room's token.
func TestEventRepo_GetEventAgendas_TracklessSessionGetsRoomColorToken(t *testing.T) {
	ctx := context.Background()
	requireColorTokenColumns(t, ctx)
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD Room Colour Conference", "2301-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2301-01-01", "Day 1", 480)

	var roomID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO rooms (config_id, name) VALUES ($1, 'TDD Keynote Room') RETURNING id",
		fixture.configID,
	).Scan(&roomID); err != nil {
		t.Fatalf("failed to insert room: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM rooms WHERE id = $1", roomID) })
	setColorToken(t, ctx, "rooms", roomID, "blue")
	setKeynoteRoom(t, ctx, fixture.configID, roomID)

	var sessionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index)
		 VALUES ($1, 'keynote', 'TDD Trackless Keynote', 6, $2, 0) RETURNING id`,
		fixture.configID, dayID,
	).Scan(&sessionID); err != nil {
		t.Fatalf("failed to insert session: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 1 {
		t.Fatalf("agendas = %+v, want one day with one session", agendas)
	}
	if got := agendas[0].Sessions[0].ColorToken; got != "blue" {
		t.Errorf("ColorToken = %q, want %q (from rooms.color_token) for a trackless but roomed session", got, "blue")
	}
}

// A session with neither room nor track has no token anywhere, and the last arm
// of the COALESCE has to answer for it. It resolves to the default rather than
// to an empty string, so colorToken is always safe to index a client-side map
// with and the client never special-cases an absent field.
//
// This is also the shape every session takes against a database below upstream
// 027, which is what makes it worth asserting unconditionally: it needs no
// color_token column to hold.
func TestEventRepo_GetEventAgendas_UnroomedUntrackedSessionsGetTheDefaultToken(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD Kind Fallback Conference", "2303-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2303-01-01", "Day 1", 480)

	// No track_id and no room_id: nothing upstream can colour these.
	insert := func(kind, title string, slot int) {
		var sessionID string
		if err := testDB.QueryRow(ctx,
			`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index)
			 VALUES ($1, $2, $3, 6, $4, $5) RETURNING id`,
			fixture.configID, kind, title, dayID, slot,
		).Scan(&sessionID); err != nil {
			t.Fatalf("failed to insert %s: %v", kind, err)
		}
		t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })
	}
	insert("keynote", "TDD Unroomed Keynote", 0)
	insert("break", "TDD Unroomed Break", 6)

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 2 {
		t.Fatalf("agendas = %+v, want one day with two sessions", agendas)
	}

	for _, s := range agendas[0].Sessions {
		if got := s.ColorToken; got != ColorTokenDefault {
			t.Errorf("%s ColorToken = %q, want %q", s.Kind, got, ColorTokenDefault)
		}
	}
}

// The precedence upstream 027 fixed, asserted on a session that has both: the
// room's token wins. This is the reverse of the hex chain it replaced, where
// the track came first -- the room is the stable thing an attendee navigates
// by, and the track is one column on one day.
func TestEventRepo_GetEventAgendas_RoomColorTokenWinsOverTrack(t *testing.T) {
	ctx := context.Background()
	requireColorTokenColumns(t, ctx)
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD Track Precedence Conference", "2304-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2304-01-01", "Day 1", 480)

	var roomID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO rooms (config_id, name) VALUES ($1, 'TDD Precedence Room') RETURNING id",
		fixture.configID,
	).Scan(&roomID); err != nil {
		t.Fatalf("failed to insert room: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM rooms WHERE id = $1", roomID) })
	setColorToken(t, ctx, "rooms", roomID, "blue")
	setKeynoteRoom(t, ctx, fixture.configID, roomID)

	trackID := insertTrack(t, ctx, dayID, &roomID)
	setColorToken(t, ctx, "tracks", trackID, "red")

	// A keynote with a token on both sides: the room's must win.
	var sessionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index, track_id)
		 VALUES ($1, 'keynote', 'TDD Tracked Keynote', 6, $2, 0, $3) RETURNING id`,
		fixture.configID, dayID, trackID,
	).Scan(&sessionID); err != nil {
		t.Fatalf("failed to insert session: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 1 {
		t.Fatalf("agendas = %+v, want one day with one session", agendas)
	}
	if got := agendas[0].Sessions[0].ColorToken; got != "blue" {
		t.Errorf("ColorToken = %q, want the room's %q to win over the track's", got, "blue")
	}
}

// A room with no token of its own is not the end of the chain: the session
// falls through to its track, and only then to the default.
func TestEventRepo_GetEventAgendas_UntokenedRoomFallsThroughToTrack(t *testing.T) {
	ctx := context.Background()
	requireColorTokenColumns(t, ctx)
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD Uncoloured Room Conference", "2302-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2302-01-01", "Day 1", 480)

	var roomID string
	if err := testDB.QueryRow(ctx,
		"INSERT INTO rooms (config_id, name) VALUES ($1, 'TDD Uncoloured Room') RETURNING id",
		fixture.configID,
	).Scan(&roomID); err != nil {
		t.Fatalf("failed to insert room: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM rooms WHERE id = $1", roomID) })

	trackID := insertTrack(t, ctx, dayID, &roomID)
	setColorToken(t, ctx, "tracks", trackID, "green")

	var sessionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index, track_id)
		 VALUES ($1, 'session', 'TDD Uncoloured Talk', 6, $2, 0, $3) RETURNING id`,
		fixture.configID, dayID, trackID,
	).Scan(&sessionID); err != nil {
		t.Fatalf("failed to insert session: %v", err)
	}
	t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 1 {
		t.Fatalf("agendas = %+v, want one day with one session", agendas)
	}
	if got := agendas[0].Sessions[0].ColorToken; got != "green" {
		t.Errorf("ColorToken = %q, want the track's %q when the room has no token", got, "green")
	}
}

// track_sections comes in two upstream kinds -- track-scoped ("Case Studies")
// and day-scoped keynote ones ("Keynote Sessions") -- and both must resolve,
// since the join is on sessions.section_id and ignores the kind.
func TestEventRepo_GetEventAgendas_ResolvesTrackGroupForBothSectionKinds(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD Track Group Conference", "2303-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2303-01-01", "Day 1", 480)

	trackID := insertTrack(t, ctx, dayID, nil)

	var trackSectionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO track_sections (track_id, label, start_slot, duration_slots, kind)
		 VALUES ($1, 'TDD Case Studies', 0, 6, 'track') RETURNING id`,
		trackID,
	).Scan(&trackSectionID); err != nil {
		t.Fatalf("failed to insert track-kind section: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM track_sections WHERE id = $1", trackSectionID)
	})

	var keynoteSectionID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO track_sections (day_id, label, start_slot, duration_slots, kind)
		 VALUES ($1, 'TDD Keynote Sessions', 6, 6, 'keynote') RETURNING id`,
		dayID,
	).Scan(&keynoteSectionID); err != nil {
		t.Fatalf("failed to insert keynote-kind section: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM track_sections WHERE id = $1", keynoteSectionID)
	})

	// The upstream sessions_validate_placement trigger pins each section kind to
	// a session kind: a track section takes only 'session', a keynote section
	// only 'keynote'.
	// A track-kind section additionally requires the session to carry that
	// section's own track_id -- sessions_validate_placement rejects the pair
	// otherwise. A keynote-kind section is day-scoped and takes none.
	for _, sec := range []struct {
		sectionID   string
		sessionKind string
		slotIndex   int
		title       string
		trackID     *string
	}{
		{trackSectionID, "session", 0, "TDD Sectioned Session", &trackID},
		{keynoteSectionID, "keynote", 6, "TDD Sectioned Keynote", nil},
	} {
		var sessionID string
		if err := testDB.QueryRow(ctx,
			`INSERT INTO sessions (config_id, kind, title, duration_slots, day_id, slot_index, section_id, track_id)
			 VALUES ($1, $2, $3, 6, $4, $5, $6, $7) RETURNING id`,
			fixture.configID, sec.sessionKind, sec.title, dayID, sec.slotIndex, sec.sectionID, sec.trackID,
		).Scan(&sessionID); err != nil {
			t.Fatalf("failed to insert session: %v", err)
		}
		t.Cleanup(func() { _, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID) })
	}

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 2 {
		t.Fatalf("agendas = %+v, want one day with two sessions", agendas)
	}

	// Ordered by slot_index, so the track-kind section comes first.
	if got := agendas[0].Sessions[0].TrackGroup; got != "TDD Case Studies" {
		t.Errorf("TrackGroup = %q, want %q (track-kind section)", got, "TDD Case Studies")
	}
	if got := agendas[0].Sessions[1].TrackGroup; got != "TDD Keynote Sessions" {
		t.Errorf("TrackGroup = %q, want %q (keynote-kind section)", got, "TDD Keynote Sessions")
	}
}

func TestEventRepo_GetEventAgendas_SessionWithNoSectionHasNoTrackGroup(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	fixture := newEventFixture(t, ctx, "TDD No Section Conference", "2304-01-01")
	dayID := fixture.insertDay(t, ctx, 0, "2304-01-01", "Day 1", 480)
	fixture.insertSession(t, ctx, dayID, 0, 6, "TDD Sectionless Session")

	agendas, err := repo.GetEventAgendas(ctx, fixture.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 1 {
		t.Fatalf("agendas = %+v, want one day with one session", agendas)
	}
	if got := agendas[0].Sessions[0].TrackGroup; got != "" {
		t.Errorf("TrackGroup = %q, want empty for a session in no section", got)
	}
}
