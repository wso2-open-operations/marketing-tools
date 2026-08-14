// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import (
	"context"
	"database/sql"
	"errors"
)

// GetAgendas returns every agenda scheduled for the given event.
func (r *Repository) GetAgendas(ctx context.Context, eventID string) ([]Agenda, error) {
	const q = `
		SELECT id, name, date
		FROM agenda
		WHERE eventId = ?`

	rows, err := r.db.QueryContext(ctx, q, eventID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	agendas := []Agenda{}
	for rows.Next() {
		var a Agenda
		if err := rows.Scan(&a.ID, &a.Name, &a.Date); err != nil {
			return nil, err
		}
		agendas = append(agendas, a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return agendas, nil
}

// InsertAgendaAttendee registers an attendee for an agenda.
func (r *Repository) InsertAgendaAttendee(ctx context.Context, attendeeID, agendaID, userEmail string) error {
	const q = `
		INSERT INTO agenda_attendee (attendee_id, agenda_id, updated_by)
		VALUES (?, ?, ?)`

	_, err := r.db.ExecContext(ctx, q, attendeeID, agendaID, userEmail)
	return err
}

// GetAgendaAttendee looks up an existing agenda registration for an
// attendee. Returns (nil, nil) if no registration exists.
func (r *Repository) GetAgendaAttendee(ctx context.Context, attendeeID, agendaID string) (*AgendaAttendee, error) {
	const q = `
		SELECT attendee_id, agenda_id
		FROM agenda_attendee
		WHERE attendee_id = ? AND agenda_id = ?`

	var a AgendaAttendee
	err := r.db.QueryRowContext(ctx, q, attendeeID, agendaID).Scan(&a.AttendeeID, &a.AgendaID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// GetAgendaAttendeeCount returns the internal/external/total attendee count
// for an agenda.
func (r *Repository) GetAgendaAttendeeCount(ctx context.Context, agendaID int) (AgendaAttendeeCount, error) {
	const q = `
		SELECT
			COUNT(CASE WHEN attendee_id LIKE ? THEN 1 END) AS internalCount,
			COUNT(CASE WHEN attendee_id NOT LIKE ? THEN 1 END) AS externalCount,
			COUNT(*) AS totalCount
		FROM agenda_attendee
		WHERE agenda_id = ?`

	likePattern := "%" + wso2Domain + "%"
	var c AgendaAttendeeCount
	err := r.db.QueryRowContext(ctx, q, likePattern, likePattern, agendaID).
		Scan(&c.InternalCount, &c.ExternalCount, &c.TotalCount)
	if err != nil {
		return AgendaAttendeeCount{}, err
	}
	return c, nil
}
