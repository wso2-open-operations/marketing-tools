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
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// EventRepo provides read access to the conference_config/conference_days
// tables (the old Ballerina "event"/"agenda" concepts -- see .claude/PLAN.md).
type EventRepo struct {
	pool        *pgxpool.Pool
	slotMinutes int
}

// NewEventRepo constructs an EventRepo backed by the given pool. slotMinutes
// is used the same way as SessionRepo's, to compute each nested session's
// StartTime/EndTime.
func NewEventRepo(pool *pgxpool.Pool, slotMinutes int) *EventRepo {
	return &EventRepo{pool: pool, slotMinutes: slotMinutes}
}

// GetEvents returns every conference_config row, ordered by start_date
// descending. IsCurrent is true only for the first (latest) row -- there is
// no stored "current" flag, so this reuses the "current = latest start_date"
// rule already established for GET /sessions/current.
func (r *EventRepo) GetEvents(ctx context.Context) ([]models.Event, error) {
	rows, err := r.pool.Query(ctx,
		"SELECT id, name FROM conference_config ORDER BY start_date DESC",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	events := make([]models.Event, 0)
	for rows.Next() {
		var e models.Event
		if err := rows.Scan(&e.ID, &e.Name); err != nil {
			return nil, err
		}
		e.IsCurrent = len(events) == 0
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

// GetEventAgendas returns every conference_days row for the given eventID,
// ordered by day_index, each with its scheduled sessions grouped in (ordered
// by slot_index). A day with zero sessions still appears, with an empty (not
// omitted) Sessions slice. An eventID with no matching conference_config
// returns an empty slice, not an error -- matches the old Ballerina
// per-day-loop behavior, where no rows was never an error case.
//
// eventID may be the literal string "current", which resolves to the
// conference_config with the latest start_date (same rule as GetEvents).
func (r *EventRepo) GetEventAgendas(ctx context.Context, eventID string) ([]models.EventAgenda, error) {
	configID := eventID
	if eventID == "current" {
		err := r.pool.QueryRow(ctx,
			"SELECT id FROM conference_config ORDER BY start_date DESC LIMIT 1",
		).Scan(&configID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return []models.EventAgenda{}, nil
			}
			return nil, err
		}
	}

	rows, err := r.pool.Query(ctx,
		`SELECT d.id, d.date, d.label, d.start_minute,
		        s.id, s.kind, s.title, s.description, s.category,
		        s.track_id, s.room_id, s.slot_index, s.duration_slots,
		        s.article_url, s.article_label, s.video_url, s.video_label
		 FROM conference_days d
		 LEFT JOIN sessions s ON s.day_id = d.id
		 WHERE d.config_id = $1
		 ORDER BY d.day_index, s.slot_index`,
		configID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	byDay := make(map[string]*models.EventAgenda)

	for rows.Next() {
		var dayID string
		var date time.Time
		var label *string
		var startMinute int
		var sessionID, kind, title, description *string
		var category, trackID, roomID *string
		var slotIndex, durationSlots *int
		var articleURL, articleLabel, videoURL, videoLabel *string

		if err := rows.Scan(
			&dayID, &date, &label, &startMinute,
			&sessionID, &kind, &title, &description, &category,
			&trackID, &roomID, &slotIndex, &durationSlots,
			&articleURL, &articleLabel, &videoURL, &videoLabel,
		); err != nil {
			return nil, err
		}

		agenda, ok := byDay[dayID]
		if !ok {
			agenda = &models.EventAgenda{
				ID:       dayID,
				EventID:  configID,
				Date:     date.Format("2006-01-02"),
				Sessions: make([]models.Session, 0),
			}
			if label != nil {
				agenda.Name = *label
			}
			byDay[dayID] = agenda
			order = append(order, dayID)
		}

		// LEFT JOIN yields one all-NULL session row for a day with no
		// sessions; skip it so the day still appears with an empty slice.
		if sessionID == nil {
			continue
		}

		session := models.Session{
			ID:            *sessionID,
			Kind:          *kind,
			Title:         *title,
			Description:   *description,
			DayID:         dayID,
			DurationSlots: *durationSlots,
			SlotIndex:     slotIndex,
		}
		if category != nil {
			session.Category = *category
		}
		if trackID != nil {
			session.TrackID = *trackID
		}
		if roomID != nil {
			session.RoomID = *roomID
		}
		if articleURL != nil {
			session.ArticleURL = *articleURL
		}
		if articleLabel != nil {
			session.ArticleLabel = *articleLabel
		}
		if videoURL != nil {
			session.VideoURL = *videoURL
		}
		if videoLabel != nil {
			session.VideoLabel = *videoLabel
		}

		if slotIndex != nil {
			start, end := computeSessionWindow(date, startMinute, *slotIndex, *durationSlots, r.slotMinutes)
			session.StartTime = &start
			session.EndTime = &end
		}

		agenda.Sessions = append(agenda.Sessions, session)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.EventAgenda, 0, len(order))
	for _, id := range order {
		result = append(result, *byDay[id])
	}
	return result, nil
}
