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
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
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
// AttendeeRepo in attendee.go, which owns the unrelated agenda_attendee
// registration-marker table. title/company/country/first_name/last_name are
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

// Insert upserts an attendee row keyed on email, mirroring the old
// insertAttendeeQuery's ON DUPLICATE KEY UPDATE semantics (see
// .claude/PLAN.md), re-keyed on email instead of the old member_id PK.
// idpUUID is the caller's authenticated JWT sub, never taken from payload,
// and is used for created_by/updated_by too (self-registration: the creator
// is the attendee).
func (r *AttendeeProfileRepo) Insert(ctx context.Context, payload models.AttendeeInsert, idpUUID string) error {
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

	_, err = r.pool.Exec(ctx,
		`INSERT INTO attendees (
			email, idp_uuid, member_id, title, company, country,
			first_name, last_name, is_partner, profile_url,
			created_by, updated_by
		) VALUES ($1, $2, NULLIF($3, ''), $4, $5, $6, $7, $8, $9, $10, $11, $11)
		ON CONFLICT (email) DO UPDATE SET
			idp_uuid = $2, member_id = NULLIF($3, ''), title = $4, company = $5, country = $6,
			first_name = $7, last_name = $8, is_partner = $9, profile_url = $10,
			updated_by = $11, updated_at = NOW()`,
		payload.Email, idpUUID, payload.MemberID, title, company, country,
		firstName, lastName, payload.IsPartner, payload.ProfileURL, idpUUID,
	)
	return err
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

// Search returns attendees excluding excludedUUID, optionally narrowed to a
// single idp_uuid, paginated. Mirrors the old getAttendees/
// getConditionQueryForAttendeesSearch behavior.
func (r *AttendeeProfileRepo) Search(ctx context.Context, filter models.AttendeeSearchFilter, excludedUUID string) (models.AttendeeSearchResult, error) {
	where := "idp_uuid != $1"
	args := []any{excludedUUID}
	if filter.UUID != "" {
		where += " AND idp_uuid = $2"
		args = append(args, filter.UUID)
	}

	var total int
	countQuery := "SELECT COUNT(*) FROM attendees WHERE " + where
	if err := r.pool.QueryRow(ctx, countQuery, args...).Scan(&total); err != nil {
		return models.AttendeeSearchResult{}, err
	}

	limitArg := len(args) + 1
	offsetArg := len(args) + 2
	query := fmt.Sprintf(
		`SELECT id, email, idp_uuid, member_id, title, company, country,
		        first_name, last_name, is_partner, profile_url,
		        created_by, updated_by, created_at, updated_at
		 FROM attendees WHERE %s
		 ORDER BY id
		 LIMIT $%d OFFSET $%d`,
		where, limitArg, offsetArg,
	)
	rows, err := r.pool.Query(ctx, query, append(args, filter.ItemsPerPage, filter.StartIndex-1)...)
	if err != nil {
		return models.AttendeeSearchResult{}, err
	}
	defer rows.Close()

	attendees := make([]models.Attendee, 0)
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
		attendees = append(attendees, a)
	}
	if err := rows.Err(); err != nil {
		return models.AttendeeSearchResult{}, err
	}

	itemsPerPage := len(attendees)
	if filter.StartIndex == 1 && total < filter.ItemsPerPage {
		itemsPerPage = total
	} else if filter.StartIndex == 1 {
		itemsPerPage = filter.ItemsPerPage
	}

	return models.AttendeeSearchResult{
		Attendees:    attendees,
		StartIndex:   filter.StartIndex,
		ItemsPerPage: itemsPerPage,
		TotalResults: total,
	}, nil
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
