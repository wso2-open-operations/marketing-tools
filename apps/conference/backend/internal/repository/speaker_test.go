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
	"encoding/base64"
	"errors"
	"testing"

	"wso2-coin-backend/internal/crypto"
)

// speakerTestKey is a throwaway 32-byte AES-256 key used only by this test
// file to encrypt fixture rows; it has no relationship to any real
// PII_ENCRYPTION_KEY.
var speakerTestKey = mustDecodeTestKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

func mustDecodeTestKey(b64 string) []byte {
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		panic(err)
	}
	return k
}

func mustEncrypt(t *testing.T, plaintext string) string {
	t.Helper()
	ct, err := crypto.EncryptPII(plaintext, speakerTestKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture value %q: %v", plaintext, err)
	}
	return ct
}

// speakerFixture inserts an isolated speaker row (and, on demand, a
// conference_config/session/session_speakers chain) for a single test, and
// registers cleanup that deletes only those specific rows.
type speakerFixture struct {
	speakerID string
}

func newSpeakerFixture(t *testing.T, ctx context.Context, name, title, bio, photoURL string, visible bool) *speakerFixture {
	t.Helper()

	var speakerID string
	err := testDB.QueryRow(ctx,
		`INSERT INTO speakers (name, title, bio, photo_url, visible)
		 VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		mustEncrypt(t, name), mustEncrypt(t, title), mustEncrypt(t, bio), photoURL, visible,
	).Scan(&speakerID)
	if err != nil {
		t.Fatalf("failed to insert test speaker: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM speakers WHERE id = $1", speakerID)
	})

	return &speakerFixture{speakerID: speakerID}
}

// attachToSession creates a minimal conference_config + session and links
// this fixture's speaker to it via session_speakers, returning
// (sessionID, configID) for assertions.
func (f *speakerFixture) attachToSession(t *testing.T, ctx context.Context) (sessionID, configID string) {
	t.Helper()

	err := testDB.QueryRow(ctx,
		"INSERT INTO conference_config (name, start_date) VALUES ($1, $2) RETURNING id",
		"TDD Speaker Test Conference", "2026-08-01",
	).Scan(&configID)
	if err != nil {
		t.Fatalf("failed to insert test conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", configID)
	})

	err = testDB.QueryRow(ctx,
		"INSERT INTO sessions (config_id, kind, title) VALUES ($1, 'session', 'TDD Speaker Test Session') RETURNING id",
		configID,
	).Scan(&sessionID)
	if err != nil {
		t.Fatalf("failed to insert test session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM sessions WHERE id = $1", sessionID)
	})

	_, err = testDB.Exec(ctx,
		"INSERT INTO session_speakers (session_id, speaker_id) VALUES ($1, $2)",
		sessionID, f.speakerID,
	)
	if err != nil {
		t.Fatalf("failed to insert test session_speakers row: %v", err)
	}

	return sessionID, configID
}

func TestSpeakerRepo_GetSpeaker_DecryptsFields(t *testing.T) {
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	fixture := newSpeakerFixture(t, ctx, "Jay Howell", "Principal Engineer", "Works on integration.", "https://example.com/jay.webp", true)

	speaker, err := repo.GetSpeaker(ctx, fixture.speakerID)
	if err != nil {
		t.Fatalf("GetSpeaker returned error: %v", err)
	}
	if speaker.Name != "Jay Howell" {
		t.Errorf("Name = %q, want %q", speaker.Name, "Jay Howell")
	}
	if speaker.Description != "Principal Engineer" {
		t.Errorf("Description = %q, want %q (mapped from title)", speaker.Description, "Principal Engineer")
	}
	if speaker.Bio != "Works on integration." {
		t.Errorf("Bio = %q, want %q", speaker.Bio, "Works on integration.")
	}
	if speaker.PhotoURL != "https://example.com/jay.webp" {
		t.Errorf("PhotoURL = %q, want %q", speaker.PhotoURL, "https://example.com/jay.webp")
	}
}

func TestSpeakerRepo_GetSpeaker_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	_, err := repo.GetSpeaker(ctx, newUUID())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetSpeaker error = %v, want ErrNotFound", err)
	}
}

func TestSpeakerRepo_GetSpeaker_NotFoundWhenNotVisible(t *testing.T) {
	// visible is a public/private access boundary, not just a list-view
	// filter: GetSpeaker must not let a hidden speaker's id bypass the same
	// check GetSpeakerSummary enforces, since this route is unauthenticated.
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	fixture := newSpeakerFixture(t, ctx, "Hidden Speaker", "", "", "", false)

	_, err := repo.GetSpeaker(ctx, fixture.speakerID)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetSpeaker error = %v, want ErrNotFound", err)
	}
}

func TestSpeakerRepo_GetSpeakerSummary_FiltersToVisibleOnly(t *testing.T) {
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	visible := newSpeakerFixture(t, ctx, "Visible Speaker", "", "", "", true)
	hidden := newSpeakerFixture(t, ctx, "Hidden Speaker", "", "", "", false)

	summaries, err := repo.GetSpeakerSummary(ctx)
	if err != nil {
		t.Fatalf("GetSpeakerSummary returned error: %v", err)
	}

	ids := make(map[string]bool)
	for _, s := range summaries {
		ids[s.ID] = true
	}
	if !ids[visible.speakerID] {
		t.Errorf("expected visible speaker %s in summary", visible.speakerID)
	}
	if ids[hidden.speakerID] {
		t.Errorf("expected hidden (visible=false) speaker %s to be excluded from summary", hidden.speakerID)
	}
}

func TestSpeakerRepo_GetSpeakerSummary_IncludesSessionSpeakers(t *testing.T) {
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	fixture := newSpeakerFixture(t, ctx, "Speaker With Session", "", "", "", true)
	sessionID, configID := fixture.attachToSession(t, ctx)

	summaries, err := repo.GetSpeakerSummary(ctx)
	if err != nil {
		t.Fatalf("GetSpeakerSummary returned error: %v", err)
	}

	var found bool
	for _, s := range summaries {
		if s.ID != fixture.speakerID {
			continue
		}
		found = true
		if len(s.SessionSpeakers) != 1 {
			t.Fatalf("expected 1 sessionSpeakers entry, got %d", len(s.SessionSpeakers))
		}
		ss := s.SessionSpeakers[0]
		if ss.SpeakerID != fixture.speakerID {
			t.Errorf("SpeakerID = %q, want %q", ss.SpeakerID, fixture.speakerID)
		}
		if ss.SessionID != sessionID {
			t.Errorf("SessionID = %q, want %q", ss.SessionID, sessionID)
		}
		if ss.EventID != configID {
			t.Errorf("EventID = %q, want %q (mapped from sessions.config_id)", ss.EventID, configID)
		}
	}
	if !found {
		t.Fatalf("expected speaker %s in summary", fixture.speakerID)
	}
}

func TestSpeakerRepo_GetSpeakerSummary_EmptySessionSpeakersIsNotNil(t *testing.T) {
	ctx := context.Background()
	repo := NewSpeakerRepo(testDB, speakerTestKey)

	fixture := newSpeakerFixture(t, ctx, "No Sessions Yet", "", "", "", true)

	summaries, err := repo.GetSpeakerSummary(ctx)
	if err != nil {
		t.Fatalf("GetSpeakerSummary returned error: %v", err)
	}

	for _, s := range summaries {
		if s.ID != fixture.speakerID {
			continue
		}
		if s.SessionSpeakers == nil {
			t.Errorf("expected non-nil (empty) SessionSpeakers slice, got nil")
		}
		if len(s.SessionSpeakers) != 0 {
			t.Errorf("expected 0 sessionSpeakers entries, got %d", len(s.SessionSpeakers))
		}
		return
	}
	t.Fatalf("expected speaker %s in summary", fixture.speakerID)
}
