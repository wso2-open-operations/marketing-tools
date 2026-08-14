// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import "context"

// GetCurrentEvent returns the event flagged as current.
func (r *Repository) GetCurrentEvent(ctx context.Context) (Event, error) {
	const q = `
		SELECT id, name, location
		FROM event
		WHERE isCurrent = 1`

	var e Event
	err := r.db.QueryRowContext(ctx, q).Scan(&e.ID, &e.Name, &e.Location)
	if err != nil {
		return Event{}, err
	}
	return e, nil
}
