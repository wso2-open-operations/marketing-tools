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
)

// GetAttendeeSummary returns one row per agenda registration for the
// current event, joined back to its agenda name.
func (r *Repository) GetAttendeeSummary(ctx context.Context) ([]AttendeeSummary, error) {
	const q = `
		SELECT
			a.name AS agenda,
			aa.attendee_id AS username,
			aa.updated_by AS scannedBy,
			CASE
				WHEN aa.attendee_id LIKE ? THEN 'Internal'
				ELSE 'External'
			END AS userType
		FROM
			agenda_attendee aa
			JOIN agenda a ON aa.agenda_id = a.id
			JOIN event e ON a.eventId = e.id
		WHERE
			e.isCurrent = 1
		ORDER BY
			a.name`

	rows, err := r.db.QueryContext(ctx, q, "%"+wso2Domain+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	summaries := []AttendeeSummary{}
	for rows.Next() {
		var s AttendeeSummary
		var scannedBy sql.NullString
		if err := rows.Scan(&s.Agenda, &s.Username, &scannedBy, &s.UserType); err != nil {
			return nil, err
		}
		if scannedBy.Valid {
			s.ScannedBy = &scannedBy.String
		}
		summaries = append(summaries, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return summaries, nil
}
