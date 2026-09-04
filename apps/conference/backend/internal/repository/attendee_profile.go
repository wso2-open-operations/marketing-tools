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
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// memberIDQRPrefix is the literal substring replaced in a member id to
// derive its QR code, matching the old Ballerina ATTENDEE_QR_PREFIX/
// memberIdPrefixRegex exactly (a literal first-occurrence substring
// replace, not a regex pattern).
const memberIDQRPrefix = "00vVM00000"

// AttendeeProfileRepo provides read/write access to the attendees table
// (the new profile table -- see .claude/PLAN.md). Kept separate from
// AttendeeRepo in attendee.go, which owns the unrelated attendee_registration
// list. title/company/country/first_name/last_name are
// encrypted at rest; piiKey encrypts/decrypts them.
type AttendeeProfileRepo struct {
	pool   *pgxpool.Pool
	piiKey []byte
}

// NewAttendeeProfileRepo constructs an AttendeeProfileRepo backed by the
// given pool, encrypting/decrypting PII fields with piiKey (see
// config.Config.PIIEncryptionKey).
func NewAttendeeProfileRepo(pool *pgxpool.Pool, piiKey []byte) *AttendeeProfileRepo {
	return &AttendeeProfileRepo{pool: pool, piiKey: piiKey}
}

// ErrEmailOwnedByAnother is returned by Insert when the email already has a
// row bound to a different idp_uuid, so the upsert was a no-op. Handlers map
// it to 409, never to a silent 201: the caller's data was not written.
//
// Declared here rather than in errors.go to keep the attendee identity fix
// self-contained.
var ErrEmailOwnedByAnother = errors.New("email already registered to another account")

// Insert upserts an attendee row keyed on email, mirroring the old
// insertAttendeeQuery's ON DUPLICATE KEY UPDATE semantics (see
// .claude/PLAN.md), re-keyed on email instead of the old member_id PK.
//
// email and idpUUID are both identity and both come from the caller's
// authenticated JWT (email claim and sub), never from payload -- payload
// carries no identity field at all. idpUUID is used for created_by/updated_by
// too (self-registration: the creator is the attendee).
//
// The conflict update is scoped to rows the caller may claim: their own row,
// or a row imported from registration that has never been bound to an IdP
// identity (idp_uuid IS NULL, migration 003). Anything else is a no-op
// reported as ErrEmailOwnedByAnother. Before that scope, a body-supplied email
// rebound a victim's row to the caller's idp_uuid and overwrote every PII
// column including member_id -- the value served as qrUri, the check-in
// credential (audit A2).
func (r *AttendeeProfileRepo) Insert(ctx context.Context, payload models.AttendeeInsert, email, idpUUID string) error {
	title, err := r.encrypt(payload.Title)
	if err != nil {
		return fmt.Errorf("encrypting title: %w", err)
	}
	company, err := r.encrypt(payload.Company)
	if err != nil {
		return fmt.Errorf("encrypting company: %w", err)
	}
	country, err := r.encrypt(payload.Country)
	if err != nil {
		return fmt.Errorf("encrypting country: %w", err)
	}
	firstName, err := r.encrypt(payload.FirstName)
	if err != nil {
		return fmt.Errorf("encrypting first name: %w", err)
	}
	lastName, err := r.encrypt(payload.LastName)
	if err != nil {
		return fmt.Errorf("encrypting last name: %w", err)
	}

	tag, err := r.pool.Exec(ctx,
		`INSERT INTO attendees (
			email, idp_uuid, member_id, title, company, country,
			first_name, last_name, is_partner, profile_url,
			created_by, updated_by
		) VALUES ($1, $2, NULLIF($3, ''), $4, $5, $6, $7, $8, $9, $10, $11, $11)
		ON CONFLICT (email) DO UPDATE SET
			idp_uuid = $2, member_id = NULLIF($3, ''), title = $4, company = $5, country = $6,
			first_name = $7, last_name = $8, is_partner = $9, profile_url = $10,
			updated_by = $11, updated_at = NOW()
		WHERE attendees.idp_uuid IS NULL OR attendees.idp_uuid = $2`,
		email, idpUUID, payload.MemberID, title, company, country,
		firstName, lastName, payload.IsPartner, payload.ProfileURL, idpUUID,
	)
	if err != nil {
		// idp_uuid and member_id are UNIQUE too: a second registration under a
		// changed email claim, or a member_id already spoken for, lands here.
		// Neither is an internal fault, so neither should be a 500.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
			return ErrEmailOwnedByAnother
		}
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrEmailOwnedByAnother
	}
	return nil
}

// GetByEmail returns a single attendee by email. Returns ErrNotFound if no
// row exists.
func (r *AttendeeProfileRepo) GetByEmail(ctx context.Context, email string) (models.Attendee, error) {
	return r.get(ctx, "email = $1", email)
}

// GetByUUID returns a single attendee by idp_uuid. Returns ErrNotFound if no
// row exists. Used internally to enrich connection responses.
func (r *AttendeeProfileRepo) GetByUUID(ctx context.Context, idpUUID string) (models.Attendee, error) {
	return r.get(ctx, "idp_uuid = $1", idpUUID)
}

func (r *AttendeeProfileRepo) get(ctx context.Context, whereClause, arg string) (models.Attendee, error) {
	var a models.Attendee
	var idpUUID, memberID, title, company, country, firstName, lastName, profileURL, createdBy, updatedBy *string

	err := r.pool.QueryRow(ctx,
		`SELECT id, email, idp_uuid, member_id, title, company, country,
		        first_name, last_name, is_partner, profile_url,
		        created_by, updated_by, created_at, updated_at
		 FROM attendees WHERE `+whereClause,
		arg,
	).Scan(
		&a.ID, &a.Email, &idpUUID, &memberID, &title, &company, &country,
		&firstName, &lastName, &a.IsPartner, &profileURL,
		&createdBy, &updatedBy, &a.CreatedAt, &a.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return models.Attendee{}, ErrNotFound
		}
		return models.Attendee{}, err
	}

	if err := r.decryptInto(&a, title, company, country, firstName, lastName); err != nil {
		return models.Attendee{}, err
	}
	if idpUUID != nil {
		a.IDPUUID = *idpUUID
	}
	if memberID != nil {
		a.MemberID = *memberID
		a.QRUri = attendeeQRFromMemberID(*memberID)
	}
	if profileURL != nil {
		a.ProfileURL = *profileURL
	}
	if createdBy != nil {
		a.CreatedBy = *createdBy
	}
	if updatedBy != nil {
		a.UpdatedBy = *updatedBy
	}
	return a, nil
}

// ListAllUUIDs returns every attendee's idp_uuid, for broadcasting a
// notification to the whole conference. Rows whose idp_uuid is still NULL are
// skipped: that column is only populated on an attendee's first IdP login
// (migration 003), and a recipient with no uuid is not addressable by the
// notification service. Ordering is unspecified -- the caller hands the whole
// list over at once.
func (r *AttendeeProfileRepo) ListAllUUIDs(ctx context.Context) ([]string, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT DISTINCT idp_uuid FROM attendees WHERE idp_uuid IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var uuids []string
	for rows.Next() {
		var uuid string
		if err := rows.Scan(&uuid); err != nil {
			return nil, err
		}
		uuids = append(uuids, uuid)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return uuids, nil
}

// PatchByEmail partially updates an attendee, leaving nil fields unchanged.
// Returns ErrNotFound if no row matches email.
func (r *AttendeeProfileRepo) PatchByEmail(ctx context.Context, email string, patch models.AttendeePatch, updatedBy string) error {
	title, err := r.encryptPtr(patch.Title)
	if err != nil {
		return fmt.Errorf("encrypting title: %w", err)
	}
	company, err := r.encryptPtr(patch.Company)
	if err != nil {
		return fmt.Errorf("encrypting company: %w", err)
	}
	country, err := r.encryptPtr(patch.Country)
	if err != nil {
		return fmt.Errorf("encrypting country: %w", err)
	}
	firstName, err := r.encryptPtr(patch.FirstName)
	if err != nil {
		return fmt.Errorf("encrypting first name: %w", err)
	}
	lastName, err := r.encryptPtr(patch.LastName)
	if err != nil {
		return fmt.Errorf("encrypting last name: %w", err)
	}

	tag, err := r.pool.Exec(ctx,
		`UPDATE attendees SET
			title = COALESCE($1, title),
			company = COALESCE($2, company),
			country = COALESCE($3, country),
			first_name = COALESCE($4, first_name),
			last_name = COALESCE($5, last_name),
			profile_url = COALESCE($6, profile_url),
			updated_by = $7,
			updated_at = NOW()
		 WHERE email = $8`,
		title, company, country, firstName, lastName, patch.ProfileURL, updatedBy, email,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// Search page-size defaults for POST /attendees/search.
const (
	defaultAttendeeSearchLimit = 20
	maxAttendeeSearchLimit     = 100
)

// Search returns attendees excluding excludedUUID (the caller's own row),
// optionally narrowed to a single idp_uuid, with an optional case-insensitive
// text query and keyset pagination.
//
// Rows are ordered by the plaintext, indexable (created_at, id) -- the only
// stable SQL ordering available, since name/company/title are encrypted at
// rest. filter.Query filters on the decrypted name/company/title in Go (an SQL
// ILIKE over the ciphertext is meaningless -- same deviation speakers made in
// Phase B). That splits the read in two: with no query the page is bounded by a
// SQL LIMIT, and with one the scan walks the keyset range and stops as soon as
// the page is full, because how many rows are needed isn't knowable in SQL.
// filter.Cursor is the opaque position returned as the previous page's
// NextCursor; a malformed cursor yields ErrInvalidCursor.
func (r *AttendeeProfileRepo) Search(ctx context.Context, filter models.AttendeeSearchFilter, excludedUUID string) (models.AttendeeSearchResult, error) {
	limit := filter.Limit
	if limit <= 0 {
		limit = defaultAttendeeSearchLimit
	}
	if limit > maxAttendeeSearchLimit {
		limit = maxAttendeeSearchLimit
	}

	// idp_uuid is nullable (migration 003): an attendee imported from
	// registration has no uuid until their first IdP login. Those rows stay out
	// of search results on purpose, because a result without a uuid can't be
	// acted on -- ConnectionUserInfo.UserID and POST /users/me/connections both
	// key off idp_uuid, and Attendee.IDPUUID is omitempty, so such a row would
	// arrive with no `uuid` field and no way to connect to it. The IS NOT NULL
	// states that intent, rather than leaving it to fall out of `NULL != $1`
	// evaluating to NULL and being filtered as not-true.
	where := "idp_uuid IS NOT NULL AND idp_uuid != $1"
	args := []any{excludedUUID}
	if filter.UUID != "" {
		where += fmt.Sprintf(" AND idp_uuid = $%d", len(args)+1)
		args = append(args, filter.UUID)
	}
	if filter.Cursor != "" {
		cursorTime, cursorID, err := decodeAttendeeCursor(filter.Cursor)
		if err != nil {
			return models.AttendeeSearchResult{}, err
		}
		where += fmt.Sprintf(" AND (created_at, id) > ($%d, $%d)", len(args)+1, len(args)+2)
		args = append(args, cursorTime, cursorID)
	}

	q := strings.ToLower(strings.TrimSpace(filter.Query))

	query := `SELECT id, email, idp_uuid, member_id, title, company, country,
	        first_name, last_name, is_partner, profile_url,
	        created_by, updated_by, created_at, updated_at
	 FROM attendees WHERE ` + where + `
	 ORDER BY created_at, id`

	// Without a text query every row matches, so a page is exactly the first
	// limit+1 rows in keyset order and the planner can serve a bounded top-N off
	// attendees_created_at_id_idx instead of sorting the whole table. With a
	// query the match runs in Go after decryption, so SQL can't know how many
	// rows are needed to fill a page and the scan has to stop early instead.
	if q == "" {
		query += fmt.Sprintf(" LIMIT $%d", len(args)+1)
		args = append(args, limit+1)
	}

	rows, err := r.pool.Query(ctx, query, args...)
	if err != nil {
		return models.AttendeeSearchResult{}, err
	}
	defer rows.Close()

	// Collect one more than the page size: the extra match tells us a further
	// page exists (and supplies its cursor) without a trailing empty page.
	items := make([]models.Attendee, 0, limit)
	hasMore := false
	for rows.Next() {
		var a models.Attendee
		var idpUUID, memberID, title, company, country, firstName, lastName, profileURL, createdBy, updatedBy *string

		if err := rows.Scan(
			&a.ID, &a.Email, &idpUUID, &memberID, &title, &company, &country,
			&firstName, &lastName, &a.IsPartner, &profileURL,
			&createdBy, &updatedBy, &a.CreatedAt, &a.UpdatedAt,
		); err != nil {
			return models.AttendeeSearchResult{}, err
		}
		if err := r.decryptInto(&a, title, company, country, firstName, lastName); err != nil {
			return models.AttendeeSearchResult{}, err
		}
		if idpUUID != nil {
			a.IDPUUID = *idpUUID
		}
		// member_id is deliberately not copied onto the result: it is the
		// check-in credential (served as qrUri), it is in no openapi Attendee
		// schema, and a directory search of every other attendee is the last
		// place it belongs. GET /attendees/me still returns the caller's own
		// (audit P2).
		_ = memberID
		if profileURL != nil {
			a.ProfileURL = *profileURL
		}
		if createdBy != nil {
			a.CreatedBy = *createdBy
		}
		if updatedBy != nil {
			a.UpdatedBy = *updatedBy
		}

		if !attendeeMatchesQuery(a, q) {
			continue
		}
		if len(items) == limit {
			hasMore = true
			break
		}
		items = append(items, a)
	}
	if err := rows.Err(); err != nil {
		return models.AttendeeSearchResult{}, err
	}

	nextCursor := ""
	if hasMore {
		last := items[len(items)-1]
		nextCursor = encodeAttendeeCursor(last.CreatedAt, last.ID)
	}

	return models.AttendeeSearchResult{
		Items: items,
		Page:  models.PageInfo{NextCursor: nextCursor},
	}, nil
}

// attendeeMatchesQuery reports whether a matches the (already lowercased,
// trimmed) query q as a case-insensitive substring of the attendee's name
// ("firstName lastName"), company, or title. An empty q matches everything.
func attendeeMatchesQuery(a models.Attendee, q string) bool {
	if q == "" {
		return true
	}
	name := strings.ToLower(strings.TrimSpace(a.FirstName + " " + a.LastName))
	return strings.Contains(name, q) ||
		strings.Contains(strings.ToLower(a.Company), q) ||
		strings.Contains(strings.ToLower(a.Title), q)
}

// encodeAttendeeCursor packs the keyset position (created_at, id) into an
// opaque, URL-safe token. The instant is normalized to UTC so the round trip
// is independent of the connection's session time zone.
func encodeAttendeeCursor(createdAt time.Time, id string) string {
	raw := createdAt.UTC().Format(time.RFC3339Nano) + "|" + id
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

// decodeAttendeeCursor reverses encodeAttendeeCursor. Any malformed input (bad
// base64, missing separator, unparseable time, id that isn't a UUID) is
// reported as ErrInvalidCursor so the handler can answer 400 rather than 500.
//
// The id has to be checked against uuidPattern, not just for emptiness:
// attendees.id is a UUID column, so a decodable cursor carrying a non-UUID id
// would otherwise reach Postgres and fail the cast in the (created_at, id)
// comparison, turning malformed client input into a 500.
func decodeAttendeeCursor(cursor string) (time.Time, string, error) {
	b, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return time.Time{}, "", ErrInvalidCursor
	}
	createdAt, id, ok := strings.Cut(string(b), "|")
	if !ok || !uuidPattern.MatchString(id) {
		return time.Time{}, "", ErrInvalidCursor
	}
	t, err := time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return time.Time{}, "", ErrInvalidCursor
	}
	return t, id, nil
}

func (r *AttendeeProfileRepo) encrypt(plaintext string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	return crypto.EncryptPII(plaintext, r.piiKey)
}

func (r *AttendeeProfileRepo) encryptPtr(plaintext *string) (*string, error) {
	if plaintext == nil {
		return nil, nil
	}
	ct, err := r.encrypt(*plaintext)
	if err != nil {
		return nil, err
	}
	return &ct, nil
}

func (r *AttendeeProfileRepo) decrypt(ciphertext *string) (string, error) {
	if ciphertext == nil || *ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(*ciphertext, r.piiKey)
	if err != nil {
		return "", fmt.Errorf("repository: decrypting PII field: %w", err)
	}
	return plaintext, nil
}

func (r *AttendeeProfileRepo) decryptInto(a *models.Attendee, title, company, country, firstName, lastName *string) error {
	var err error
	if a.Title, err = r.decrypt(title); err != nil {
		return fmt.Errorf("decrypting title: %w", err)
	}
	if a.Company, err = r.decrypt(company); err != nil {
		return fmt.Errorf("decrypting company: %w", err)
	}
	if a.Country, err = r.decrypt(country); err != nil {
		return fmt.Errorf("decrypting country: %w", err)
	}
	if a.FirstName, err = r.decrypt(firstName); err != nil {
		return fmt.Errorf("decrypting first name: %w", err)
	}
	if a.LastName, err = r.decrypt(lastName); err != nil {
		return fmt.Errorf("decrypting last name: %w", err)
	}
	return nil
}

// attendeeQRFromMemberID derives the attendee's QR code from their member
// id, porting getAttendeeQrFromMemberId/ATTENDEE_QR_PREFIX exactly: replace
// only the first occurrence of the literal substring "00vVM00000" with "WC".
func attendeeQRFromMemberID(memberID string) string {
	return strings.Replace(memberID, memberIDQRPrefix, "WC", 1)
}
