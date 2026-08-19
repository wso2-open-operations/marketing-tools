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
	"strings"
	"time"

	"attendee-registration/internal/crypto"
)

// GetAgendas returns every session scheduled for the given event (a
// conference_config id). Registrant no longer owns an agenda table -- this
// reads the shared sessions/conference_days tables, the same way
// apps/conference/backend's own repos do.
func (r *Repository) GetAgendas(ctx context.Context, eventID string) ([]Agenda, error) {
	const q = `
		SELECT s.id, s.title, d.date
		FROM sessions s
		JOIN conference_days d ON s.day_id = d.id
		WHERE s.config_id = $1`

	rows, err := r.db.QueryContext(ctx, q, eventID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	agendas := []Agenda{}
	for rows.Next() {
		var a Agenda
		var date time.Time
		if err := rows.Scan(&a.ID, &a.Name, &date); err != nil {
			return nil, err
		}
		a.Date = date.Format("2006-01-02")
		agendas = append(agendas, a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return agendas, nil
}

// InsertAgendaAttendee registers an attendee for an agenda (a session, per
// the shared schema). The attendee's email is encrypted at rest; lookups
// against it can't use a SQL WHERE (see GetAgendaAttendee) since encryption
// is non-deterministic.
func (r *Repository) InsertAgendaAttendee(ctx context.Context, attendeeID, agendaID, userEmail string) error {
	encrypted, err := crypto.Encrypt(attendeeID)
	if err != nil {
		return err
	}

	const q = `
		INSERT INTO attendee_registration (attendee_id, session_id, updated_by)
		VALUES ($1, $2, $3)`

	_, err = r.db.ExecContext(ctx, q, encrypted, agendaID, userEmail)
	return err
}

// GetAgendaAttendee looks up an existing agenda registration for an
// attendee. Returns (nil, nil) if no registration exists. attendee_id is
// encrypted at rest and non-deterministic, so this can't filter by it in
// SQL -- it fetches every registration for the agenda and decrypts each to
// compare.
func (r *Repository) GetAgendaAttendee(ctx context.Context, attendeeID, agendaID string) (*AgendaAttendee, error) {
	const q = `SELECT attendee_id FROM attendee_registration WHERE session_id = $1`

	rows, err := r.db.QueryContext(ctx, q, agendaID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var encrypted string
		if err := rows.Scan(&encrypted); err != nil {
			return nil, err
		}
		email, err := crypto.Decrypt(encrypted)
		if err != nil {
			return nil, err
		}
		if email == attendeeID {
			return &AgendaAttendee{AttendeeID: attendeeID, AgendaID: agendaID}, nil
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return nil, nil
}

// GetAgendaAttendeeCount returns the internal/external/total attendee count
// for an agenda. attendee_id is encrypted at rest, so classification
// happens after decrypting each row rather than via a SQL LIKE.
func (r *Repository) GetAgendaAttendeeCount(ctx context.Context, agendaID string) (AgendaAttendeeCount, error) {
	const q = `SELECT attendee_id FROM attendee_registration WHERE session_id = $1`

	rows, err := r.db.QueryContext(ctx, q, agendaID)
	if err != nil {
		return AgendaAttendeeCount{}, err
	}
	defer rows.Close()

	var c AgendaAttendeeCount
	for rows.Next() {
		var encrypted string
		if err := rows.Scan(&encrypted); err != nil {
			return AgendaAttendeeCount{}, err
		}
		email, err := crypto.Decrypt(encrypted)
		if err != nil {
			return AgendaAttendeeCount{}, err
		}
		if strings.HasSuffix(strings.ToLower(email), wso2Domain) {
			c.InternalCount++
		} else {
			c.ExternalCount++
		}
		c.TotalCount++
	}
	if err := rows.Err(); err != nil {
		return AgendaAttendeeCount{}, err
	}
	return c, nil
}
