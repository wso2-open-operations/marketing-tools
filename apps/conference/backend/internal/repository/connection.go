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
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// ConnectionRepo provides read/write access to the user_connection table
// (the new "network connections" feature -- see .claude/PLAN.md).
type ConnectionRepo struct {
	pool      *pgxpool.Pool
	attendees *AttendeeProfileRepo
}

// NewConnectionRepo constructs a ConnectionRepo backed by the given pool.
// attendees is used to decrypt each connection's enriched user info -- the
// same PII fields (name/title/company/country) speakers and attendees
// already encrypt at rest.
func NewConnectionRepo(pool *pgxpool.Pool, attendees *AttendeeProfileRepo) *ConnectionRepo {
	return &ConnectionRepo{pool: pool, attendees: attendees}
}

// Get returns userUUID's connections, bucketed into sent/received requests
// and accepted connections, each enriched with the other user's attendee
// profile. One SQL join instead of the old code's N+1 (one query for
// connections, one per row for user details) -- same feature, ported as one
// idiomatic query. Because name-bearing fields are encrypted, the join
// fetches raw columns only; decryption and name assembly happen in Go,
// after the join, same order of operations as
// SpeakerRepo.GetSpeakerSummary's per-row decrypt-after-join.
func (r *ConnectionRepo) Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT uc.initiator_id, uc.recipient_id, uc.status,
		        a.idp_uuid, a.email, a.first_name, a.last_name,
		        a.title, a.company, a.country, a.profile_url
		 FROM user_connection uc
		 JOIN attendees a ON a.idp_uuid = CASE WHEN uc.initiator_id = $1 THEN uc.recipient_id ELSE uc.initiator_id END
		 WHERE uc.status != -1 AND (uc.initiator_id = $1 OR uc.recipient_id = $1)`,
		userUUID,
	)
	if err != nil {
		return models.UserConnectionsInfo{}, err
	}
	defer rows.Close()

	info := models.UserConnectionsInfo{
		RequestsSent:     make([]models.ConnectionUserInfo, 0),
		RequestsReceived: make([]models.ConnectionUserInfo, 0),
		Connections:      make([]models.ConnectionUserInfo, 0),
	}

	for rows.Next() {
		var initiatorID, recipientID string
		var status int
		var idpUUID, email, firstName, lastName, title, company, country, profileURL *string

		if err := rows.Scan(
			&initiatorID, &recipientID, &status,
			&idpUUID, &email, &firstName, &lastName, &title, &company, &country, &profileURL,
		); err != nil {
			return models.UserConnectionsInfo{}, err
		}

		decryptedFirst, err := r.attendees.decrypt(firstName)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}
		decryptedLast, err := r.attendees.decrypt(lastName)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}
		decryptedTitle, err := r.attendees.decrypt(title)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}
		decryptedCompany, err := r.attendees.decrypt(company)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}
		decryptedCountry, err := r.attendees.decrypt(country)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}

		user := models.ConnectionUserInfo{
			Title:   decryptedTitle,
			Company: decryptedCompany,
			Country: decryptedCountry,
		}
		if idpUUID != nil {
			user.UserID = *idpUUID
		}
		if email != nil {
			user.Email = *email
		}
		if profileURL != nil {
			user.ProfileURL = *profileURL
		}
		user.Name = strings.TrimSpace(decryptedFirst + " " + decryptedLast)

		switch {
		case models.ConnectionStatus(status) == models.ConnectionAccepted:
			info.Connections = append(info.Connections, user)
		case initiatorID == userUUID:
			info.RequestsSent = append(info.RequestsSent, user)
		default:
			info.RequestsReceived = append(info.RequestsReceived, user)
		}
	}
	if err := rows.Err(); err != nil {
		return models.UserConnectionsInfo{}, err
	}

	return info, nil
}

// Upsert creates or updates a connection between initiatorUUID and
// recipientUUID. If a connection already exists between the two in either
// direction, its stored direction is reused rather than always writing
// (initiatorUUID, recipientUUID) -- porting the old insertOrUpdateUserConnection's
// canonicalization exactly, since changing it would allow a duplicate
// (A,B)/(B,A) pair.
func (r *ConnectionRepo) Upsert(ctx context.Context, initiatorUUID, recipientUUID string, status models.ConnectionStatus) error {
	initiator, recipient := initiatorUUID, recipientUUID

	var existingInitiator string
	err := r.pool.QueryRow(ctx,
		`SELECT initiator_id FROM user_connection
		 WHERE (initiator_id = $1 AND recipient_id = $2) OR (initiator_id = $2 AND recipient_id = $1)
		 LIMIT 1`,
		initiatorUUID, recipientUUID,
	).Scan(&existingInitiator)
	switch {
	case err == nil:
		if existingInitiator == recipientUUID {
			initiator, recipient = recipientUUID, initiatorUUID
		}
	case errors.Is(err, pgx.ErrNoRows):
		// no existing row; use the given direction.
	default:
		return err
	}

	_, err = r.pool.Exec(ctx,
		`INSERT INTO user_connection (initiator_id, recipient_id, status)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (initiator_id, recipient_id) DO UPDATE SET status = excluded.status`,
		initiator, recipient, int(status),
	)
	return err
}
