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

// connectionColumns is the full row projection, shared by every statement
// that returns a connection so the Scan order in scanConnection stays valid
// no matter which one produced the row.
const connectionColumns = `id, requester_id, addressee_id, state, created_at, updated_at`

// ConnectionRepo provides read/write access to the user_connection table:
// one row per unordered pair of attendees, keyed on a generated
// (pair_low, pair_high) unique constraint rather than on a direction. See
// migrations/014_user_connection_redesign.sql and
// .claude/PLAN.connections-redesign.md for why the directional shape had to
// go -- every authorization bug in this feature came out of it.
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

// rowScanner is satisfied by both pgx.Row and pgx.Rows, so scanConnection can
// serve QueryRow callers and a future multi-row read alike.
type rowScanner interface {
	Scan(dest ...any) error
}

// scanConnection reads one connectionColumns projection into a Connection.
func scanConnection(row rowScanner) (models.Connection, error) {
	var c models.Connection
	var state string
	if err := row.Scan(&c.ID, &c.RequesterID, &c.AddresseeID, &state, &c.CreatedAt, &c.UpdatedAt); err != nil {
		return models.Connection{}, err
	}
	c.State = models.ConnectionState(state)
	return c, nil
}

// Get returns userUUID's connections, bucketed into sent/received requests
// and accepted connections, each enriched with the other user's attendee
// profile. One SQL join instead of the old code's N+1 (one query for
// connections, one per row for user details). Because the name-bearing
// columns are encrypted, the join fetches ciphertext only; decryption and
// name assembly happen in Go after the join, the same order of operations as
// SpeakerRepo.GetSpeakerSummary's per-row decrypt-after-join.
//
// Every returned item carries ConnectionID. The accept and delete routes
// address a connection by its row id and nothing else, so a client holding a
// GET response would otherwise have no handle to act on.
//
// The three slices are always non-nil: the microapp iterates them directly
// and a JSON `null` would break that, so an empty bucket must serialize as
// [].
func (r *ConnectionRepo) Get(ctx context.Context, userUUID string) (models.UserConnectionsInfo, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT uc.id, uc.requester_id, uc.state,
		        a.idp_uuid, a.email, a.first_name, a.last_name,
		        a.title, a.company, a.country, a.profile_url
		 FROM user_connection uc
		 JOIN attendees a ON a.idp_uuid = CASE WHEN uc.requester_id = $1 THEN uc.addressee_id ELSE uc.requester_id END
		 WHERE uc.requester_id = $1 OR uc.addressee_id = $1`,
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
		var connectionID, requesterID, state string
		var idpUUID, email, firstName, lastName, title, company, country, profileURL *string

		if err := rows.Scan(
			&connectionID, &requesterID, &state,
			&idpUUID, &email, &firstName, &lastName, &title, &company, &country, &profileURL,
		); err != nil {
			return models.UserConnectionsInfo{}, err
		}

		plain, err := r.decryptAll(firstName, lastName, title, company, country)
		if err != nil {
			return models.UserConnectionsInfo{}, err
		}

		user := models.ConnectionUserInfo{
			ConnectionID: connectionID,
			Status:       models.ConnectionState(state).String(),
			Name:         strings.TrimSpace(plain[0] + " " + plain[1]),
			Title:        plain[2],
			Company:      plain[3],
			Country:      plain[4],
		}
		if idpUUID != nil {
			user.UserID = *idpUUID
		}
		// The address is released only once the pair is actually connected.
		// A pending row shows up in both parties' responses, so populating it
		// unconditionally handed the recipient's email to whoever sent the
		// request, with no action by the recipient at all.
		if email != nil && models.ConnectionState(state) == models.ConnectionAccepted {
			user.Email = *email
		}
		if profileURL != nil {
			user.ProfileURL = *profileURL
		}

		// A pending row is a *sent* request only for the party that
		// started it; the pair itself no longer records a direction
		// anywhere else, which is exactly why requester_id is kept.
		switch {
		case models.ConnectionState(state) == models.ConnectionAccepted:
			info.Connections = append(info.Connections, user)
		case requesterID == userUUID:
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

// decryptAll decrypts the encrypted-at-rest profile columns in one pass, so
// the scan loop is not five near-identical four-line error checks.
func (r *ConnectionRepo) decryptAll(ciphertexts ...*string) ([]string, error) {
	plain := make([]string, len(ciphertexts))
	for i, c := range ciphertexts {
		v, err := r.attendees.decrypt(c)
		if err != nil {
			return nil, err
		}
		plain[i] = v
	}
	return plain, nil
}

// Request records a pending connection from requesterUUID to addresseeUUID
// and returns the row that now represents the pair.
//
// Target validation and the write happen inside one transaction, in that
// order. Before the redesign a request to a nonexistent user answered 404 and
// still left a user_connection row behind, because the row was written first
// and the attendee lookup that failed the request happened afterwards, in a
// separate statement.
//
// The insert is ON CONFLICT (pair_low, pair_high) DO NOTHING and falls back
// to reading the existing row, which makes two things true at once: a repeat
// request is idempotent rather than an error, and a request sent in the
// reverse direction while a row already exists returns that row untouched
// instead of creating the mirror row the old directional key allowed. Note
// the fallback deliberately returns the row *unchanged* -- B requesting A
// while A's request to B is pending must not silently flip the requester, or
// B would then be allowed to accept what is really their own request.
func (r *ConnectionRepo) Request(ctx context.Context, requesterUUID, addresseeUUID string) (models.Connection, error) {
	// The user_connection_no_self CHECK refuses this too, but a constraint
	// violation reaches the handler as an opaque driver error; naming it
	// here is what lets the handler answer 400 rather than 500.
	if requesterUUID == addresseeUUID {
		return models.Connection{}, ErrSelfConnection
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return models.Connection{}, err
	}
	// Rollback is a no-op once the tx has committed, so this is safe
	// unconditionally and guarantees no path leaks an open transaction.
	defer func() { _ = tx.Rollback(ctx) }()

	var exists int
	err = tx.QueryRow(ctx, `SELECT 1 FROM attendees WHERE idp_uuid = $1`, addresseeUUID).Scan(&exists)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.Connection{}, ErrNotFound
	}
	if err != nil {
		return models.Connection{}, err
	}

	conn, err := scanConnection(tx.QueryRow(ctx,
		`INSERT INTO user_connection (requester_id, addressee_id)
		 VALUES ($1, $2)
		 ON CONFLICT ON CONSTRAINT user_connection_pair_unique DO NOTHING
		 RETURNING `+connectionColumns,
		requesterUUID, addresseeUUID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		// DO NOTHING suppressed the RETURNING row, which means the pair
		// already exists -- in either direction, at either state.
		conn, err = scanConnection(tx.QueryRow(ctx,
			`SELECT `+connectionColumns+` FROM user_connection
			 WHERE pair_low = LEAST($1, $2) AND pair_high = GREATEST($1, $2)`,
			requesterUUID, addresseeUUID,
		))
	}
	if err != nil {
		return models.Connection{}, err
	}

	if err := tx.Commit(ctx); err != nil {
		return models.Connection{}, err
	}
	return conn, nil
}

// Accept moves a pending connection to accepted on behalf of callerUUID, who
// must be its addressee, and returns the updated row.
//
// The state machine lives in the WHERE clause rather than in a read-then-write
// pair of statements: only a row that is still pending and whose addressee is
// the caller can be updated, so a concurrent accept and delete cannot
// interleave into an accepted row that one party already removed. There is
// deliberately no path back from accepted to pending.
//
// When the update matches nothing the row is re-read purely to say why, and
// the distinction matters: a requester trying to accept their own request is
// the bug this redesign exists to close, so it gets its own error, while a
// caller who is not a party at all is told ErrNotFound. Answering 403 to a
// stranger would confirm that the id exists.
func (r *ConnectionRepo) Accept(ctx context.Context, connectionID, callerUUID string) (models.Connection, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return models.Connection{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	conn, err := scanConnection(tx.QueryRow(ctx,
		`UPDATE user_connection SET state = 'accepted'
		 WHERE id = $1 AND addressee_id = $2 AND state = 'pending'
		 RETURNING `+connectionColumns,
		connectionID, callerUUID,
	))
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return models.Connection{}, err
		}
		return conn, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return models.Connection{}, err
	}

	existing, err := scanConnection(tx.QueryRow(ctx,
		`SELECT `+connectionColumns+` FROM user_connection WHERE id = $1`,
		connectionID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return models.Connection{}, ErrNotFound
	}
	if err != nil {
		return models.Connection{}, err
	}

	switch {
	case existing.RequesterID == callerUUID:
		return models.Connection{}, ErrConnectionForbidden
	case existing.AddresseeID == callerUUID:
		// The caller is the right person, so the only remaining reason
		// the update matched nothing is that the row already moved on.
		return models.Connection{}, ErrConnectionNotPending
	default:
		return models.Connection{}, ErrNotFound
	}
}

// Delete removes the connection, which is how decline, withdraw and remove
// are all expressed: there is no 'declined' state, so a refused pair simply
// stops having a row and is free to connect again later.
//
// Either party may delete, at either state, so ownership is a clause in the
// DELETE rather than a read followed by a check -- one statement, no window
// between the two. A miss reports ErrNotFound whether the id does not exist
// or belongs to two other people, on the same don't-confirm-the-id reasoning
// as Accept.
func (r *ConnectionRepo) Delete(ctx context.Context, connectionID, callerUUID string) error {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM user_connection
		 WHERE id = $1 AND (requester_id = $2 OR addressee_id = $2)`,
		connectionID, callerUUID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
