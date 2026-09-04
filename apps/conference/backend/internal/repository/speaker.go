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
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// SpeakerRepo provides read access to the speakers/session_speakers tables.
// name/title/bio are encrypted at rest (see internal/crypto); piiKey decrypts
// them on read. loc anchors each embedded session's times to the venue
// timezone (see config.Config.VenueLocation).
type SpeakerRepo struct {
	pool        *pgxpool.Pool
	piiKey      []byte
	slotMinutes int
	loc         *time.Location
	// caps shapes the colour-token SELECT against whatever upstream revision
	// the shared schema is actually at (see schema.go).
	caps schemaCaps
}

// NewSpeakerRepo constructs a SpeakerRepo backed by the given pool, decrypting
// PII fields with piiKey (see config.Config.PIIEncryptionKey). slotMinutes/loc
// compute and anchor the times of the sessions embedded on each speaker; a nil
// loc defaults to UTC.
func NewSpeakerRepo(pool *pgxpool.Pool, piiKey []byte, slotMinutes int, loc *time.Location) *SpeakerRepo {
	if loc == nil {
		loc = time.UTC
	}
	return &SpeakerRepo{pool: pool, piiKey: piiKey, slotMinutes: slotMinutes, loc: loc}
}

// GetSpeaker returns a single visible speaker by id, with the sessions they
// are on in the current conference embedded as resolved SpeakerSession
// objects (title + real times + room name and colours). This is the whole
// speaker detail screen in one response: nothing here needs a second request
// or a client-side join.
//
// Unlike the old Ballerina getSpeaker(id), this filters on visible = true:
// visible is a new access boundary the old schema never had, and this route is
// public/unauthenticated, so a hidden speaker's id must not be a back door
// around the same visibility check GetSpeakerSummary enforces. Returns
// ErrNotFound if no matching visible row exists.
func (r *SpeakerRepo) GetSpeaker(ctx context.Context, id string) (models.Speaker, error) {
	var speaker models.Speaker
	var name, title, bio string
	var photoURL *string

	err := r.pool.QueryRow(ctx,
		"SELECT id, name, title, bio, photo_url FROM speakers WHERE id = $1 AND visible",
		id,
	).Scan(&speaker.ID, &name, &title, &bio, &photoURL)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return models.Speaker{}, ErrNotFound
		}
		return models.Speaker{}, err
	}

	if speaker.Name, err = r.decrypt(name); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting name: %w", err)
	}
	if speaker.Description, err = r.decrypt(title); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting title: %w", err)
	}
	if speaker.Bio, err = r.decrypt(bio); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting bio: %w", err)
	}
	if photoURL != nil {
		speaker.PhotoURL = *photoURL
	}

	if speaker.Sessions, err = r.fetchSpeakerSessions(ctx, speaker.ID); err != nil {
		return models.Speaker{}, err
	}

	return speaker, nil
}

// fetchSpeakerSessions returns the sessions the given speaker is on in the
// current conference (the conference_config with the latest start_date -- the
// same "current" rule GetEvents and GetCurrentSessions use), resolved to the
// shape the speaker detail screen renders and ordered by start time.
//
// Scoping to the current conference preserves what the client used to get for
// free: the speaker list it read these off is event-scoped, so an unscoped
// query here would start surfacing a speaker's talks from past conferences on
// their profile. Returns an empty, never nil, slice for a speaker with no
// sessions.
func (r *SpeakerRepo) fetchSpeakerSessions(ctx context.Context, speakerID string) ([]models.SpeakerSession, error) {
	rows, err := r.pool.Query(ctx,
		fmt.Sprintf(
			`SELECT s.id, s.title, s.slot_index, s.duration_slots,
			        d.date, d.start_minute, cc.timezone, r.name, %s
			 FROM session_speakers ss
			 JOIN sessions s ON s.id = ss.session_id
			 LEFT JOIN conference_days d ON d.id = s.day_id
			 LEFT JOIN conference_config cc ON cc.id = s.config_id
			 LEFT JOIN rooms r ON r.id = s.room_id
			 LEFT JOIN tracks t ON t.id = s.track_id
			 WHERE ss.speaker_id = $1
			   AND s.config_id = (SELECT id FROM conference_config ORDER BY start_date DESC, id DESC LIMIT 1)`,
			r.caps.colorTokenSQL(ctx, r.pool),
		),
		speakerID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	sessions := make([]models.SpeakerSession, 0)
	for rows.Next() {
		var sessionID, title, colorToken string
		var cfgTZ, roomName *string
		var slotIndex, durationSlots, startMinute *int
		var date *time.Time

		if err := rows.Scan(&sessionID, &title, &slotIndex, &durationSlots,
			&date, &startMinute, &cfgTZ, &roomName, &colorToken); err != nil {
			return nil, err
		}

		sess := models.SpeakerSession{ID: sessionID, Title: title, ColorToken: colorToken}
		if roomName != nil {
			sess.RoomName = *roomName
		}
		if slotIndex != nil && durationSlots != nil && date != nil && startMinute != nil {
			start, end := computeSessionWindow(*date, *startMinute, *slotIndex, *durationSlots, r.slotMinutes, resolveLoc(cfgTZ, r.loc))
			sess.StartTime = &start
			sess.EndTime = &end
		}
		sessions = append(sessions, sess)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	sort.SliceStable(sessions, func(i, j int) bool {
		return sessionStartsBefore(sessions[i], sessions[j])
	})
	return sessions, nil
}

// GetSpeakerSummary returns the visible speakers a directory listing renders,
// sorted by name. It embeds no sessions: the list screen draws none, and a
// client that wants a speaker's sessions reads GET /speakers/:id, which
// resolves them there (see fetchSpeakerSessions).
//
// filter.EventID restricts to speakers with at least one session in that
// conference_config. filter.Query is a case-insensitive substring match over
// the decrypted name, title and company, so "wso2" finds the people whose
// company says WSO2 rather than nothing. Company is not part of the returned
// row; it is read only to be searched. Both the ordering and the search run in
// Go because those columns are encrypted at rest -- an SQL ORDER BY / ILIKE
// over the ciphertext would be meaningless, so there is no index to push this
// into (see
// migrations/008_attendee_search_index.sql, which hit the same wall). The cost
// is one extra decrypt per row per searchable field; the directory is a few
// hundred rows and already decrypts every one of them.
//
// A row this key cannot decrypt is skipped, not fatal: the serving key is not
// necessarily the key every historical row was written with, and returning the
// other 262 speakers beats 500ing the whole directory over one of them.
func (r *SpeakerRepo) GetSpeakerSummary(ctx context.Context, filter models.SpeakerFilter) ([]models.SpeakerSummary, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT sp.id, sp.name, sp.title, sp.bio, sp.company, sp.photo_url
		 FROM speakers sp
		 WHERE sp.visible
		   AND ($1 = '' OR EXISTS (
		         SELECT 1 FROM session_speakers ss
		         JOIN sessions s ON s.id = ss.session_id
		         WHERE ss.speaker_id = sp.id AND s.config_id = $1::uuid))`,
		filter.EventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	q := strings.ToLower(strings.TrimSpace(filter.Query))
	summaries := make([]models.SpeakerSummary, 0)

	for rows.Next() {
		var id, name, title, bio string
		var company, photoURL *string

		if err := rows.Scan(&id, &name, &title, &bio, &company, &photoURL); err != nil {
			return nil, err
		}

		// The id is the whole log line on purpose: the field that failed to
		// decrypt is PII, and so is the ciphertext.
		decryptedName, err := r.decrypt(name)
		if err != nil {
			slog.WarnContext(ctx, "skipping speaker with undecryptable field", "speakerId", id, "field", "name")
			continue
		}
		decryptedTitle, err := r.decrypt(title)
		if err != nil {
			slog.WarnContext(ctx, "skipping speaker with undecryptable field", "speakerId", id, "field", "title")
			continue
		}
		// company is nullable, and is read only to be searched -- it is not
		// part of the directory row.
		decryptedCompany := ""
		if company != nil {
			if decryptedCompany, err = r.decrypt(*company); err != nil {
				slog.WarnContext(ctx, "skipping speaker with undecryptable field", "speakerId", id, "field", "company")
				continue
			}
		}
		if q != "" && !matchesAny(q, decryptedName, decryptedTitle, decryptedCompany) {
			continue
		}
		decryptedBio, err := r.decrypt(bio)
		if err != nil {
			slog.WarnContext(ctx, "skipping speaker with undecryptable field", "speakerId", id, "field", "bio")
			continue
		}

		summary := models.SpeakerSummary{
			ID:          id,
			Name:        decryptedName,
			Description: decryptedTitle,
			Bio:         decryptedBio,
		}
		if photoURL != nil {
			summary.PhotoURL = *photoURL
		}
		summaries = append(summaries, summary)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	sort.SliceStable(summaries, func(i, j int) bool {
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return summaries, nil
}

// matchesAny reports whether q (already lowercased and trimmed) is a substring
// of any of the given fields, case-insensitively.
func matchesAny(q string, fields ...string) bool {
	for _, f := range fields {
		if strings.Contains(strings.ToLower(f), q) {
			return true
		}
	}
	return false
}

// sessionStartsBefore orders SpeakerSessions by start time, with unscheduled
// sessions (nil StartTime) sorting last.
func sessionStartsBefore(a, b models.SpeakerSession) bool {
	if a.StartTime == nil {
		return false
	}
	if b.StartTime == nil {
		return true
	}
	return a.StartTime.Before(*b.StartTime)
}

func (r *SpeakerRepo) decrypt(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(ciphertext, r.piiKey)
	if err != nil {
		return "", fmt.Errorf("repository: decrypting PII field: %w", err)
	}
	return plaintext, nil
}
