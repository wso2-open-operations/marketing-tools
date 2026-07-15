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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// AttendeeRepo provides read access to the agenda_attendee table, which is
// the registration list synced from the agenda-organizer app.
type AttendeeRepo struct {
	pool *pgxpool.Pool
}

// NewAttendeeRepo constructs an AttendeeRepo backed by the given pool.
func NewAttendeeRepo(pool *pgxpool.Pool) *AttendeeRepo {
	return &AttendeeRepo{pool: pool}
}

// IsRegistered reports whether the given email/attendee id is a registered
// attendee. A missing row is not an error; it simply reports false.
func (r *AttendeeRepo) IsRegistered(ctx context.Context, email string) (bool, error) {
	var one int
	err := r.pool.QueryRow(ctx, "SELECT 1 FROM agenda_attendee WHERE attendee_id = $1 LIMIT 1", email).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}
