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
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// SessionRepo provides read access to scheduling information for sessions.
// piiKey decrypts speaker names joined in via session_speakers/speakers (see
// internal/crypto) for GetSessionPresenters.
type SessionRepo struct {
	pool        *pgxpool.Pool
	slotMinutes int
	piiKey      []byte
}

// NewSessionRepo constructs a SessionRepo backed by the given pool.
// slotMinutes converts a session's slot_index/duration_slots into minutes
// relative to its day's start_minute (see config.Config.SessionSlotMinutes).
func NewSessionRepo(pool *pgxpool.Pool, slotMinutes int, piiKey []byte) *SessionRepo {
	return &SessionRepo{pool: pool, slotMinutes: slotMinutes, piiKey: piiKey}
}

// GetTimeWindow returns the wall-clock start and end time of a scheduled
// session, computed from its day's date + start_minute, plus
// slot_index/duration_slots converted to minutes via slotMinutes.
//
// Returns ErrNotFound if the session doesn't exist, or if it has no
// day_id/slot_index (i.e. it's unscheduled -- can't have a time window).
//
// Both returned times are in UTC (the schema has no timezone info; day.date
// is treated as UTC midnight).
func (r *SessionRepo) GetTimeWindow(ctx context.Context, sessionID string) (start, end time.Time, err error) {
	var durationSlots int
	var slotIndex *int
	var date *time.Time
	var startMinute *int

	queryErr := r.pool.QueryRow(ctx,
		`SELECT s.slot_index, s.duration_slots, d.date, d.start_minute
		 FROM sessions s
		 LEFT JOIN conference_days d ON s.day_id = d.id
		 WHERE s.id = $1`,
		sessionID,
	).Scan(&slotIndex, &durationSlots, &date, &startMinute)
	if queryErr != nil {
		if errors.Is(queryErr, pgx.ErrNoRows) {
			return time.Time{}, time.Time{}, ErrNotFound
		}
		return time.Time{}, time.Time{}, queryErr
	}

	if slotIndex == nil || date == nil || startMinute == nil {
		// Session exists but is unscheduled (no day_id / slot_index): no
		// time window can be computed.
		return time.Time{}, time.Time{}, ErrNotFound
	}

	dayMidnight := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, time.UTC)
	start = dayMidnight.Add(time.Duration(*startMinute+*slotIndex*r.slotMinutes) * time.Minute)
	end = dayMidnight.Add(time.Duration(*startMinute+(*slotIndex+durationSlots)*r.slotMinutes) * time.Minute)
	return start, end, nil
}

// GetSession returns a single session by id, computing StartTime/EndTime
// from its day + slot_index (see GetTimeWindow) in the same query rather
// than a second round trip. StartTime/EndTime stay nil, with no error, when
// the session is unscheduled (day_id/slot_index are NULL) -- that's a valid
// state for a session to be in, not a missing-row error.
//
// Returns ErrNotFound if no session with this id exists.
func (r *SessionRepo) GetSession(ctx context.Context, id string) (models.Session, error) {
	var s models.Session
	var category, dayID, trackID, roomID *string
	var articleURL, articleLabel, videoURL, videoLabel *string
	var slotIndex *int
	var date *time.Time
	var startMinute *int

	err := r.pool.QueryRow(ctx,
		`SELECT s.id, s.kind, s.title, s.description, s.category,
		        s.day_id, s.slot_index, s.duration_slots, s.track_id, s.room_id,
		        s.article_url, s.article_label, s.video_url, s.video_label,
		        d.date, d.start_minute
		 FROM sessions s
		 LEFT JOIN conference_days d ON s.day_id = d.id
		 WHERE s.id = $1`,
		id,
	).Scan(
		&s.ID, &s.Kind, &s.Title, &s.Description, &category,
		&dayID, &slotIndex, &s.DurationSlots, &trackID, &roomID,
		&articleURL, &articleLabel, &videoURL, &videoLabel,
		&date, &startMinute,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return models.Session{}, ErrNotFound
		}
		return models.Session{}, err
	}

	if category != nil {
		s.Category = *category
	}
	if dayID != nil {
		s.DayID = *dayID
	}
	if trackID != nil {
		s.TrackID = *trackID
	}
	if roomID != nil {
		s.RoomID = *roomID
	}
	if articleURL != nil {
		s.ArticleURL = *articleURL
	}
	if articleLabel != nil {
		s.ArticleLabel = *articleLabel
	}
	if videoURL != nil {
		s.VideoURL = *videoURL
	}
	if videoLabel != nil {
		s.VideoLabel = *videoLabel
	}
	s.SlotIndex = slotIndex

	if slotIndex != nil && date != nil && startMinute != nil {
		dayMidnight := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, time.UTC)
		start := dayMidnight.Add(time.Duration(*startMinute+*slotIndex*r.slotMinutes) * time.Minute)
		end := dayMidnight.Add(time.Duration(*startMinute+(*slotIndex+s.DurationSlots)*r.slotMinutes) * time.Minute)
		s.StartTime = &start
		s.EndTime = &end
	}

	return s, nil
}

// GetSessionPresenters returns, for every session in the "current" conference
// (the conference_config with the latest start_date -- see .claude/PLAN.md),
// its id, title, and the decrypted names of every speaker attached to it. A
// session with no session_speakers rows is excluded, matching the old
// Ballerina query's inner-join semantics.
func (r *SessionRepo) GetSessionPresenters(ctx context.Context) ([]models.SessionPresenters, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT s.id, s.title, sp.name
		 FROM sessions s
		 JOIN session_speakers ss ON ss.session_id = s.id
		 JOIN speakers sp ON sp.id = ss.speaker_id
		 WHERE s.config_id = (SELECT id FROM conference_config ORDER BY start_date DESC LIMIT 1)
		 ORDER BY s.id`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	bySession := make(map[string]*models.SessionPresenters)

	for rows.Next() {
		var id, title, encryptedName string
		if err := rows.Scan(&id, &title, &encryptedName); err != nil {
			return nil, err
		}

		name, err := r.decrypt(encryptedName)
		if err != nil {
			return nil, err
		}

		presenters, ok := bySession[id]
		if !ok {
			presenters = &models.SessionPresenters{ID: id, Name: title, Presenters: make([]string, 0)}
			bySession[id] = presenters
			order = append(order, id)
		}
		presenters.Presenters = append(presenters.Presenters, name)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.SessionPresenters, 0, len(order))
	for _, id := range order {
		result = append(result, *bySession[id])
	}
	return result, nil
}

func (r *SessionRepo) decrypt(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(ciphertext, r.piiKey)
	if err != nil {
		return "", fmt.Errorf("repository: decrypting PII field: %w", err)
	}
	return plaintext, nil
}
