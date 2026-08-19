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

// GetCurrentEvent returns the conference_config row with the latest
// start_date. Registrant no longer owns an event table -- there's no stored
// "current" flag in the shared schema, so this uses the same "current =
// latest start_date" rule apps/conference/backend's own EventRepo uses.
func (r *Repository) GetCurrentEvent(ctx context.Context) (Event, error) {
	const q = `
		SELECT id, name, venue_name, venue_address
		FROM conference_config
		ORDER BY start_date DESC
		LIMIT 1`

	var e Event
	var venueName, venueAddress sql.NullString
	err := r.db.QueryRowContext(ctx, q).Scan(&e.ID, &e.Name, &venueName, &venueAddress)
	if err != nil {
		return Event{}, err
	}
	e.Location = joinVenue(venueName, venueAddress)
	return e, nil
}

// joinVenue combines conference_config's separate venue_name/venue_address
// columns into the single Location string the API contract already exposes.
func joinVenue(name, address sql.NullString) string {
	switch {
	case name.Valid && address.Valid:
		return name.String + ", " + address.String
	case name.Valid:
		return name.String
	case address.Valid:
		return address.String
	default:
		return ""
	}
}
