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

	"wso2-coin-backend/internal/models"
)

// agendaSpeakerFixture builds one conference with one day carrying two
// sessions that share a slot_index, the second of which has a speaker. The tie
// is the point: without a deterministic tiebreak the planner picks the order,
// and the agenda disagreed with /sessions/current on 40 of 85 in-slot
// positions.
type agendaSpeakerFixture struct {
	configID  string
	sessionA  string
	sessionB  string
	speakerID string
}

func newAgendaSpeakerFixture(t *testing.T, ctx context.Context) *agendaSpeakerFixture {
	t.Helper()

	f := &agendaSpeakerFixture{}
	if err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date, timezone) VALUES ($1, $2, 'UTC') RETURNING id",
		"TDD Agenda Speakers Conference", "2098-08-01",
	).Scan(&f.configID); err != nil {
		t.Fatalf("failed to insert conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", f.configID)
	})

	var dayID string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO conference_days (config_id, day_index, date, start_minute, end_minute, label)
		 VALUES ($1, 0, $2, 480, 1020, 'Day 1') RETURNING id`,
		f.configID, "2098-08-01",
	).Scan(&dayID); err != nil {
		t.Fatalf("failed to insert conference_day: %v", err)
	}

	// Both sessions sit in the same slot, so only the id tiebreak orders them.
	// They are inserted lowest-id-last so a query that relies on insertion
	// order fails this test.
	f.sessionB = insertAgendaSession(t, ctx, f.configID, dayID, "ZZZ Second By Id")
	f.sessionA = insertAgendaSession(t, ctx, f.configID, dayID, "AAA First By Id")
	if f.sessionA > f.sessionB {
		f.sessionA, f.sessionB = f.sessionB, f.sessionA
	}

	fixture := newSpeakerFixture(t, ctx, "Agenda Speaker", "Staff Engineer", "", "", true)
	f.speakerID = fixture.speakerID
	if _, err := testDB.Exec(ctx,
		"INSERT INTO session_speakers (session_id, speaker_id) VALUES ($1, $2)",
		f.sessionA, f.speakerID,
	); err != nil {
		t.Fatalf("failed to link speaker to session: %v", err)
	}

	return f
}

func insertAgendaSession(t *testing.T, ctx context.Context, configID, dayID, title string) string {
	t.Helper()
	var id string
	if err := testDB.QueryRow(ctx,
		`INSERT INTO sessions (config_id, day_id, kind, title, description, slot_index, duration_slots)
		 VALUES ($1, $2, 'session', $3, $4, 0, 12) RETURNING id`,
		configID, dayID, title, "<p>"+title+" description</p>",
	).Scan(&id); err != nil {
		t.Fatalf("failed to insert session %q: %v", title, err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", id)
	})
	return id
}

// The agenda is the AI service's source for a session's speakers; it returned
// none, so picked-for-you shipped empty sessionSpeakers. Both agenda routes
// share this query, so this pins them to the same shape GET /sessions/:id and
// GET /sessions/current already serve.
func TestEventRepo_GetEventAgendas_EmbedsSpeakersAndDescription(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	f := newAgendaSpeakerFixture(t, ctx)

	agendas, err := repo.GetEventAgendas(ctx, f.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 {
		t.Fatalf("len(agendas) = %d, want 1", len(agendas))
	}

	var withSpeaker *models.Session
	for i := range agendas[0].Sessions {
		if agendas[0].Sessions[i].ID == f.sessionA {
			withSpeaker = &agendas[0].Sessions[i]
		}
		if agendas[0].Sessions[i].Description == "" {
			t.Errorf("session %s has an empty description", agendas[0].Sessions[i].ID)
		}
	}
	if withSpeaker == nil {
		t.Fatalf("session %s missing from the agenda", f.sessionA)
	}
	if len(withSpeaker.Speakers) != 1 {
		t.Fatalf("speakers = %+v, want the one linked speaker", withSpeaker.Speakers)
	}
	if withSpeaker.Speakers[0].ID != f.speakerID || withSpeaker.Speakers[0].Name != "Agenda Speaker" {
		t.Errorf("speaker = %+v, want the decrypted fixture speaker", withSpeaker.Speakers[0])
	}
	if withSpeaker.Speakers[0].Title != "Staff Engineer" {
		t.Errorf("speaker title = %q, want %q", withSpeaker.Speakers[0].Title, "Staff Engineer")
	}
}

// Two sessions in one slot must come back in the same order /sessions/current
// puts them in, which is the id tiebreak (see SessionRepo.GetCurrentSessions).
func TestEventRepo_GetEventAgendas_OrdersTiedSlotsByID(t *testing.T) {
	ctx := context.Background()
	repo := NewEventRepo(testDB, 5, speakerTestKey, time.UTC, "UTC")

	f := newAgendaSpeakerFixture(t, ctx)

	agendas, err := repo.GetEventAgendas(ctx, f.configID)
	if err != nil {
		t.Fatalf("GetEventAgendas returned error: %v", err)
	}
	if len(agendas) != 1 || len(agendas[0].Sessions) != 2 {
		t.Fatalf("agendas = %+v, want one day with two sessions", agendas)
	}
	got := []string{agendas[0].Sessions[0].ID, agendas[0].Sessions[1].ID}
	if got[0] != f.sessionA || got[1] != f.sessionB {
		t.Errorf("session order = %v, want ascending id %v", got, []string{f.sessionA, f.sessionB})
	}
}
