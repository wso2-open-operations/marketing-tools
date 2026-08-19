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
	"strings"

	"attendee-registration/internal/crypto"
)

// GetAttendeeSummary returns one row per agenda (session) registration for
// the current event, joined back to its session title. attendee_id is
// encrypted at rest, so this decrypts each row here to produce Username and
// to classify UserType, since neither can be done in SQL against
// ciphertext.
func (r *Repository) GetAttendeeSummary(ctx context.Context) ([]AttendeeSummary, error) {
	const q = `
		SELECT
			s.title AS agenda,
			ar.attendee_id AS username,
			ar.updated_by AS scannedBy
		FROM
			attendee_registration ar
			JOIN sessions s ON ar.session_id = s.id
		WHERE
			s.config_id = (SELECT id FROM conference_config ORDER BY start_date DESC LIMIT 1)
		ORDER BY
			s.title`

	rows, err := r.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	summaries := []AttendeeSummary{}
	for rows.Next() {
		var s AttendeeSummary
		var encrypted string
		var scannedBy sql.NullString
		if err := rows.Scan(&s.Agenda, &encrypted, &scannedBy); err != nil {
			return nil, err
		}
		email, err := crypto.Decrypt(encrypted)
		if err != nil {
			return nil, err
		}
		s.Username = email
		if strings.HasSuffix(email, wso2Domain) {
			s.UserType = "Internal"
		} else {
			s.UserType = "External"
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
