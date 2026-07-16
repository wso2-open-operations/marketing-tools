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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// pgUniqueViolation is the Postgres SQLSTATE for a unique constraint violation.
const pgUniqueViolation = "23505"

// CoinAllocationRepo provides read/write access to the coin_allocation table.
type CoinAllocationRepo struct {
	pool *pgxpool.Pool
}

// NewCoinAllocationRepo constructs a CoinAllocationRepo backed by the given pool.
func NewCoinAllocationRepo(pool *pgxpool.Pool) *CoinAllocationRepo {
	return &CoinAllocationRepo{pool: pool}
}

// Exists reports whether a coin_allocation row already exists for this
// (qrID, userUUID) pair, regardless of status.
func (r *CoinAllocationRepo) Exists(ctx context.Context, qrID, userUUID string) (bool, error) {
	var one int
	err := r.pool.QueryRow(ctx,
		"SELECT 1 FROM coin_allocation WHERE qr_id = $1 AND user_uuid = $2 LIMIT 1",
		qrID, userUUID,
	).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// Insert creates a new coin_allocation row and returns it with generated
// id/created_at/updated_at populated. Returns ErrDuplicateAllocation if a row
// for this (qr_id, user_uuid) pair already exists — this can happen even
// after a caller's preceding Exists check passed, since two concurrent scans
// of the same QR by the same user can both pass Exists before either inserts.
func (r *CoinAllocationRepo) Insert(ctx context.Context, alloc models.CoinAllocation) (models.CoinAllocation, error) {
	err := r.pool.QueryRow(ctx,
		`INSERT INTO coin_allocation (qr_id, event_type, user_uuid, wallet_address, coins_allocated, transaction_status, event_data)
		 VALUES ($1,$2,$3,$4,$5,$6,$7)
		 RETURNING id, created_at, updated_at`,
		alloc.QrID, string(alloc.EventType), alloc.UserUUID, alloc.WalletAddress,
		alloc.CoinsAllocated, string(alloc.TransactionStatus), []byte(alloc.EventData),
	).Scan(&alloc.ID, &alloc.CreatedAt, &alloc.UpdatedAt)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
			return models.CoinAllocation{}, ErrDuplicateAllocation
		}
		return models.CoinAllocation{}, err
	}
	return alloc, nil
}

// UpdateStatus updates the transaction_status (and updated_at) of the row
// matching (qrID, userUUID).
func (r *CoinAllocationRepo) UpdateStatus(ctx context.Context, qrID, userUUID string, status models.TransactionStatus) error {
	_, err := r.pool.Exec(ctx,
		"UPDATE coin_allocation SET transaction_status = $1, updated_at = now() WHERE qr_id = $2 AND user_uuid = $3",
		string(status), qrID, userUUID,
	)
	return err
}

// History returns GENERAL-event-type rows for this user, folding
// FAILED/PROCESSING into PENDING for display, ordered by created_at
// descending.
func (r *CoinAllocationRepo) History(ctx context.Context, userUUID string) ([]models.CoinAllocationHistory, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT coins_allocated, created_at,
		        CASE WHEN transaction_status IN ('FAILED','PROCESSING') THEN 'PENDING' ELSE transaction_status END AS status,
		        event_data->>'eventTypeName' AS event_type_name
		 FROM coin_allocation
		 WHERE user_uuid = $1 AND event_type = 'GENERAL'
		 ORDER BY created_at DESC`,
		userUUID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	history := make([]models.CoinAllocationHistory, 0)
	for rows.Next() {
		var h models.CoinAllocationHistory
		var status string
		var eventTypeName *string
		if err := rows.Scan(&h.CoinsAllocated, &h.CreatedOn, &status, &eventTypeName); err != nil {
			return nil, err
		}
		h.TransactionStatus = models.TransactionStatus(status)
		if eventTypeName != nil {
			h.EventTypeName = *eventTypeName
		}
		history = append(history, h)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return history, nil
}

// Summary sums coins for GENERAL-event-type rows: totalPending = sum where
// status in (PENDING,PROCESSING,FAILED), totalTransferred = sum where
// status = TRANSFERRED.
func (r *CoinAllocationRepo) Summary(ctx context.Context, userUUID string) (models.CoinAllocationSummary, error) {
	var summary models.CoinAllocationSummary
	err := r.pool.QueryRow(ctx,
		`SELECT
		    COALESCE(SUM(coins_allocated) FILTER (WHERE transaction_status IN ('PENDING','PROCESSING','FAILED')), 0) AS total_pending,
		    COALESCE(SUM(coins_allocated) FILTER (WHERE transaction_status = 'TRANSFERRED'), 0) AS total_transferred
		 FROM coin_allocation
		 WHERE user_uuid = $1 AND event_type = 'GENERAL'`,
		userUUID,
	).Scan(&summary.TotalPending, &summary.TotalTransferred)
	if err != nil {
		return models.CoinAllocationSummary{}, err
	}
	return summary, nil
}
