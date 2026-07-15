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
)

// SessionRepo provides read access to scheduling information for sessions.
type SessionRepo struct {
	pool        *pgxpool.Pool
	slotMinutes int
}

// NewSessionRepo constructs a SessionRepo backed by the given pool.
// slotMinutes converts a session's slot_index/duration_slots into minutes
// relative to its day's start_minute (see config.Config.SessionSlotMinutes).
func NewSessionRepo(pool *pgxpool.Pool, slotMinutes int) *SessionRepo {
	return &SessionRepo{pool: pool, slotMinutes: slotMinutes}
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
