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

	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
)

// AttendeeRepo answers "is this person a registered attendee?" from
// attendee_registration, the registration list the agenda-organizer app writes
// (one row per attendee x session, FK'd to sessions) and apps/registrant/backend
// owns.
//
// attendee_registration.attendee_id holds the attendee's email *encrypted* with
// the shared PII key (same versioned AES-256-GCM format as speakers.name etc.),
// verified against staging. AES-GCM uses a random nonce, so the same address
// encrypts to a different string every time and no equality predicate can be
// pushed into SQL -- the candidate ids have to be decrypted here and compared.
type AttendeeRepo struct {
	pool   *pgxpool.Pool
	piiKey []byte
}

// NewAttendeeRepo constructs an AttendeeRepo backed by the given pool,
// decrypting attendee ids with piiKey (see config.Config.PIIEncryptionKey).
func NewAttendeeRepo(pool *pgxpool.Pool, piiKey []byte) *AttendeeRepo {
	return &AttendeeRepo{pool: pool, piiKey: piiKey}
}

// IsRegistered reports whether the given email belongs to a registered
// attendee. Registration for any single session counts as registration for the
// event: attendee_registration has no event-level grain, and the old
// event-level table it replaced was never populated.
//
// DISTINCT keeps the scan to one row per attendee rather than one per
// attendee x session, and it is served by the (attendee_id, session_id) primary
// key as an index-only scan. A row that will not decrypt is skipped, not
// fatal -- one bad registration must not stop everyone else earning coins.
//
// A missing row is not an error; it simply reports false.
func (r *AttendeeRepo) IsRegistered(ctx context.Context, email string) (bool, error) {
	needle := strings.TrimSpace(email)
	if needle == "" {
		return false, nil
	}

	rows, err := r.pool.Query(ctx, "SELECT DISTINCT attendee_id FROM attendee_registration")
	if err != nil {
		return false, err
	}
	defer rows.Close()

	for rows.Next() {
		var stored string
		if err := rows.Scan(&stored); err != nil {
			return false, err
		}
		// Tolerate a plaintext id as well as an encrypted one: nothing in the
		// schema enforces the encryption, and a plaintext writer must not
		// silently stop matching.
		if strings.EqualFold(strings.TrimSpace(stored), needle) {
			return true, nil
		}
		plain, decErr := crypto.DecryptPII(stored, r.piiKey)
		if decErr != nil {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(plain), needle) {
			return true, nil
		}
	}
	return false, rows.Err()
}
