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

// GetSpeaker returns a single visible speaker by id. Unlike the old Ballerina
// getSpeaker(id), this filters on visible = true: visible is a new access
// boundary the old schema never had, and this route is public/unauthenticated,
// so a hidden speaker's id must not be a back door around the same
// visibility check GetSpeakerSummary enforces. Returns ErrNotFound if no
// matching visible row exists.
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

	return speaker, nil
}

// GetSpeakerSummary returns visible speakers, each with the sessions they're
// attached to embedded as resolved SpeakerSession objects (title + real
// times) so the client needs no join back to sessions (FE.md 3.2). A speaker
// with no sessions still appears (with an empty, never nil, Sessions slice)
// unless an EventID filter is set.
//
// filter.EventID restricts to speakers with at least one session in that
// conference_config (showing only those sessions). filter.Query is a
// case-insensitive substring match on the decrypted name. Both name ordering
// and the name search run in Go because name is encrypted at rest -- an SQL
// ORDER BY / ILIKE over the ciphertext would be meaningless. Result is sorted
// by name; each speaker's sessions are sorted by start time.
func (r *SpeakerRepo) GetSpeakerSummary(ctx context.Context, filter models.SpeakerFilter) ([]models.SpeakerSummary, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT sp.id, sp.name, sp.title, sp.bio, sp.photo_url,
		        s.id, s.title, s.slot_index, s.duration_slots, d.date, d.start_minute, cc.timezone
		 FROM speakers sp
		 LEFT JOIN session_speakers ss ON ss.speaker_id = sp.id
		 LEFT JOIN sessions s ON s.id = ss.session_id
		 LEFT JOIN conference_days d ON d.id = s.day_id
		 LEFT JOIN conference_config cc ON cc.id = s.config_id
		 WHERE sp.visible AND ($1 = '' OR s.config_id = $1::uuid)`,
		filter.EventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	bySpeaker := make(map[string]*models.SpeakerSummary)

	for rows.Next() {
		var id, name, title, bio string
		var photoURL, sessionID, sessionTitle, cfgTZ *string
		var slotIndex, durationSlots, startMinute *int
		var date *time.Time

		if err := rows.Scan(&id, &name, &title, &bio, &photoURL,
			&sessionID, &sessionTitle, &slotIndex, &durationSlots, &date, &startMinute, &cfgTZ); err != nil {
			return nil, err
		}

		summary, ok := bySpeaker[id]
		if !ok {
			decryptedName, err := r.decrypt(name)
			if err != nil {
				return nil, fmt.Errorf("decrypting name: %w", err)
			}
			decryptedTitle, err := r.decrypt(title)
			if err != nil {
				return nil, fmt.Errorf("decrypting title: %w", err)
			}
			decryptedBio, err := r.decrypt(bio)
			if err != nil {
				return nil, fmt.Errorf("decrypting bio: %w", err)
			}

			summary = &models.SpeakerSummary{
				ID:          id,
				Name:        decryptedName,
				Description: decryptedTitle,
				Bio:         decryptedBio,
				Sessions:    make([]models.SpeakerSession, 0),
			}
			if photoURL != nil {
				summary.PhotoURL = *photoURL
			}
			bySpeaker[id] = summary
			order = append(order, id)
		}

		if sessionID != nil {
			sess := models.SpeakerSession{ID: *sessionID}
			if sessionTitle != nil {
				sess.Title = *sessionTitle
			}
			if slotIndex != nil && durationSlots != nil && date != nil && startMinute != nil {
				start, end := computeSessionWindow(*date, *startMinute, *slotIndex, *durationSlots, r.slotMinutes, resolveLoc(cfgTZ, r.loc))
				sess.StartTime = &start
				sess.EndTime = &end
			}
			summary.Sessions = append(summary.Sessions, sess)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	q := strings.ToLower(strings.TrimSpace(filter.Query))
	summaries := make([]models.SpeakerSummary, 0, len(order))
	for _, id := range order {
		s := bySpeaker[id]
		if q != "" && !strings.Contains(strings.ToLower(s.Name), q) {
			continue
		}
		sort.SliceStable(s.Sessions, func(i, j int) bool {
			return sessionStartsBefore(s.Sessions[i], s.Sessions[j])
		})
		summaries = append(summaries, *s)
	}
	sort.SliceStable(summaries, func(i, j int) bool {
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return summaries, nil
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
