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

	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
)

// AttendeeRepo provides read access to the attendee_registration table
// (renamed from agenda_attendee, now owned by apps/registrant/backend),
// the registration list synced from the agenda-organizer app.
type AttendeeRepo struct {
	pool   *pgxpool.Pool
	piiKey []byte
}

// NewAttendeeRepo constructs an AttendeeRepo backed by the given pool,
// decrypting attendee_id with piiKey (see config.Config.PIIEncryptionKey).
func NewAttendeeRepo(pool *pgxpool.Pool, piiKey []byte) *AttendeeRepo {
	return &AttendeeRepo{pool: pool, piiKey: piiKey}
}

// IsRegistered reports whether the given email/attendee id has at least one
// registration row. attendee_id is encrypted at rest with a random nonce
// per row, so identical plaintext never produces identical ciphertext -- a
// SQL WHERE can't filter by it, so this decrypts rows until it finds a
// match instead.
func (r *AttendeeRepo) IsRegistered(ctx context.Context, email string) (bool, error) {
	rows, err := r.pool.Query(ctx, "SELECT attendee_id FROM attendee_registration")
	if err != nil {
		return false, err
	}
	defer rows.Close()

	for rows.Next() {
		var encrypted string
		if err := rows.Scan(&encrypted); err != nil {
			return false, err
		}
		decrypted, err := crypto.DecryptPII(encrypted, r.piiKey)
		if err != nil {
			return false, err
		}
		if decrypted == email {
			return true, nil
		}
	}
	return false, rows.Err()
}
