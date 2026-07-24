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
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// uuidPattern guards DayIDsForSessions against non-UUID ids from the external
// recommendation service, so a stray id can't turn a uuid[] bind into a 500.
var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// SessionRepo provides read access to scheduling information for sessions.
// piiKey decrypts speaker names joined in via session_speakers/speakers (see
// internal/crypto). loc anchors the schema's zone-less day+slot times to a
// wall clock so the API can emit offset-bearing instants (see
// config.Config.VenueLocation).
type SessionRepo struct {
	pool        *pgxpool.Pool
	slotMinutes int
	piiKey      []byte
	loc         *time.Location
}

// NewSessionRepo constructs a SessionRepo backed by the given pool.
// slotMinutes converts a session's slot_index/duration_slots into minutes
// relative to its day's start_minute (see config.Config.SessionSlotMinutes).
// loc is the venue timezone the computed times are anchored to; a nil loc
// defaults to UTC.
func NewSessionRepo(pool *pgxpool.Pool, slotMinutes int, piiKey []byte, loc *time.Location) *SessionRepo {
	if loc == nil {
		loc = time.UTC
	}
	return &SessionRepo{pool: pool, slotMinutes: slotMinutes, piiKey: piiKey, loc: loc}
}

// GetTimeWindow returns the wall-clock start and end time of a scheduled
// session, computed from its day's date + start_minute, plus
// slot_index/duration_slots converted to minutes via slotMinutes.
//
// Returns ErrNotFound if the session doesn't exist, or if it has no
// day_id/slot_index (i.e. it's unscheduled -- can't have a time window).
//
// Both returned times are anchored to the owning conference's timezone
// (conference_config.timezone, the source of truth), falling back to the
// env-configured r.loc only when that column is empty. day.date is treated as
// local midnight in that zone; the absolute instant is what the O2C
// slot-window check compares against, so anchoring to the right zone keeps the
// scan window correct in real time.
func (r *SessionRepo) GetTimeWindow(ctx context.Context, sessionID string) (start, end time.Time, err error) {
	var durationSlots int
	var slotIndex *int
	var date *time.Time
	var startMinute *int
	var cfgTZ *string

	queryErr := r.pool.QueryRow(ctx,
		`SELECT s.slot_index, s.duration_slots, d.date, d.start_minute, cc.timezone
		 FROM sessions s
		 LEFT JOIN conference_days d ON s.day_id = d.id
		 LEFT JOIN conference_config cc ON cc.id = s.config_id
		 WHERE s.id = $1`,
		sessionID,
	).Scan(&slotIndex, &durationSlots, &date, &startMinute, &cfgTZ)
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

	start, end = computeSessionWindow(*date, *startMinute, *slotIndex, durationSlots, r.slotMinutes, resolveLoc(cfgTZ, r.loc))
	return start, end, nil
}

// computeSessionWindow computes a scheduled session's wall-clock start/end
// time from its day's date + start_minute, plus slot_index/duration_slots
// converted to minutes via slotMinutes. loc anchors the wall clock to the
// venue timezone so the resulting instants serialize with a real offset
// (e.g. +05:30) instead of a fake Z; a nil loc defaults to UTC. Shared by
// GetTimeWindow, GetSession, GetCurrentSessions, and
// EventRepo.GetEventAgendas — the real call sites for the same arithmetic
// (see .claude/PLAN.md).
func computeSessionWindow(date time.Time, startMinute, slotIndex, durationSlots, slotMinutes int, loc *time.Location) (start, end time.Time) {
	if loc == nil {
		loc = time.UTC
	}
	dayMidnight := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, loc)
	start = dayMidnight.Add(time.Duration(startMinute+slotIndex*slotMinutes) * time.Minute)
	end = dayMidnight.Add(time.Duration(startMinute+(slotIndex+durationSlots)*slotMinutes) * time.Minute)
	return start, end
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
	var trackColor, roomName, cfgTZ *string
	var slotIndex *int
	var date *time.Time
	var startMinute *int

	err := r.pool.QueryRow(ctx,
		`SELECT s.id, s.kind, s.title, s.description, s.category,
		        s.day_id, s.slot_index, s.duration_slots, s.track_id, s.room_id,
		        s.article_url, s.article_label, s.video_url, s.video_label,
		        d.date, d.start_minute, t.color, r.name, cc.timezone
		 FROM sessions s
		 LEFT JOIN conference_days d ON s.day_id = d.id
		 LEFT JOIN tracks t ON t.id = s.track_id
		 LEFT JOIN rooms r ON r.id = s.room_id
		 LEFT JOIN conference_config cc ON cc.id = s.config_id
		 WHERE s.id = $1`,
		id,
	).Scan(
		&s.ID, &s.Kind, &s.Title, &s.Description, &category,
		&dayID, &slotIndex, &s.DurationSlots, &trackID, &roomID,
		&articleURL, &articleLabel, &videoURL, &videoLabel,
		&date, &startMinute, &trackColor, &roomName, &cfgTZ,
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
	if trackColor != nil {
		s.TrackColor = *trackColor
	}
	if roomName != nil {
		s.RoomName = *roomName
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
		start, end := computeSessionWindow(*date, *startMinute, *slotIndex, s.DurationSlots, r.slotMinutes, resolveLoc(cfgTZ, r.loc))
		s.StartTime = &start
		s.EndTime = &end
	}

	speakers, err := fetchSessionSpeakers(ctx, r.pool, r.piiKey, []string{s.ID})
	if err != nil {
		return models.Session{}, err
	}
	s.Speakers = speakers[s.ID]
	if s.Speakers == nil {
		s.Speakers = make([]models.SessionSpeaker, 0)
	}

	return s, nil
}

// GetCurrentSessions returns every session in the "current" conference (the
// conference_config with the latest start_date -- see .claude/PLAN.md) in the
// same shape as GetSession, ordered by wall-clock start time (day date, then
// slot). Unscheduled sessions (no day/slot) sort last with nil Start/EndTime.
//
// This replaces the old GetSessionPresenters {id, name, presenters[]} shape so
// GET /sessions/current shares one Session renderer with the agenda endpoints
// (see .claude/PLAN.md cross-cutting). It no longer inner-joins speakers, so a
// session with no speakers (breaks, registration) is now included rather than
// dropped; embedded speaker objects arrive in Phase B.
func (r *SessionRepo) GetCurrentSessions(ctx context.Context) ([]models.Session, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT s.id, s.kind, s.title, s.description, s.category,
		        s.day_id, s.slot_index, s.duration_slots, s.track_id, s.room_id,
		        s.article_url, s.article_label, s.video_url, s.video_label,
		        d.date, d.start_minute, t.color, r.name, cc.timezone
		 FROM sessions s
		 LEFT JOIN conference_days d ON s.day_id = d.id
		 LEFT JOIN tracks t ON t.id = s.track_id
		 LEFT JOIN rooms r ON r.id = s.room_id
		 LEFT JOIN conference_config cc ON cc.id = s.config_id
		 WHERE s.config_id = (SELECT id FROM conference_config ORDER BY start_date DESC LIMIT 1)
		 ORDER BY d.date NULLS LAST, s.slot_index NULLS LAST, s.id`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	result := make([]models.Session, 0)
	for rows.Next() {
		var s models.Session
		var category, dayID, trackID, roomID *string
		var articleURL, articleLabel, videoURL, videoLabel *string
		var trackColor, roomName, cfgTZ *string
		var slotIndex *int
		var date *time.Time
		var startMinute *int

		if err := rows.Scan(
			&s.ID, &s.Kind, &s.Title, &s.Description, &category,
			&dayID, &slotIndex, &s.DurationSlots, &trackID, &roomID,
			&articleURL, &articleLabel, &videoURL, &videoLabel,
			&date, &startMinute, &trackColor, &roomName, &cfgTZ,
		); err != nil {
			return nil, err
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
		if trackColor != nil {
			s.TrackColor = *trackColor
		}
		if roomName != nil {
			s.RoomName = *roomName
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
			start, end := computeSessionWindow(*date, *startMinute, *slotIndex, s.DurationSlots, r.slotMinutes, resolveLoc(cfgTZ, r.loc))
			s.StartTime = &start
			s.EndTime = &end
		}

		result = append(result, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	ids := make([]string, len(result))
	for i := range result {
		ids[i] = result[i].ID
	}
	speakers, err := fetchSessionSpeakers(ctx, r.pool, r.piiKey, ids)
	if err != nil {
		return nil, err
	}
	for i := range result {
		result[i].Speakers = speakers[result[i].ID]
		if result[i].Speakers == nil {
			result[i].Speakers = make([]models.SessionSpeaker, 0)
		}
	}
	return result, nil
}

// DayIDsForSessions returns a map from session id to its conference_days id,
// for the subset of the given ids that are scheduled (day_id not null). Ids
// that don't resolve to a scheduled session are simply absent from the map.
// Used to day-associate picked-for-you recommendations (see .claude/PLAN.md
// Phase E). Non-UUID ids are skipped rather than erroring, since the ids come
// from an external service whose id scheme this backend doesn't control.
func (r *SessionRepo) DayIDsForSessions(ctx context.Context, sessionIDs []string) (map[string]string, error) {
	result := make(map[string]string)
	valid := make([]string, 0, len(sessionIDs))
	for _, id := range sessionIDs {
		if uuidPattern.MatchString(id) {
			valid = append(valid, id)
		}
	}
	if len(valid) == 0 {
		return result, nil
	}

	rows, err := r.pool.Query(ctx,
		`SELECT id, day_id FROM sessions WHERE id = ANY($1) AND day_id IS NOT NULL`,
		valid,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var id, dayID string
		if err := rows.Scan(&id, &dayID); err != nil {
			return nil, err
		}
		result[id] = dayID
	}
	if err := rows.Err(); err != nil {
		return nil, err
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
