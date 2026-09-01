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
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

type LeaderboardRepo struct {
	pool   *pgxpool.Pool
	piiKey []byte
}

func NewLeaderboardRepo(pool *pgxpool.Pool, piiKey []byte) *LeaderboardRepo {
	return &LeaderboardRepo{pool: pool, piiKey: piiKey}
}

const maxLeaderboardLimit = 100

func (r *LeaderboardRepo) GetLeaderboard(ctx context.Context, limit int, eventID string) ([]models.LeaderboardEntry, error) {
	if limit <= 0 {
		limit = 10
	}
	if limit > maxLeaderboardLimit {
		limit = maxLeaderboardLimit
	}

	query := `
		SELECT 
			c.user_uuid,
			SUM(c.coins_allocated) as total_coins,
			a.first_name, a.last_name, a.show_full_name
		FROM coin_allocation c
		JOIN attendees a ON c.user_uuid = a.idp_uuid::uuid
		WHERE c.event_id = $1 AND c.transaction_status = 'TRANSFERRED'
		GROUP BY c.user_uuid, a.first_name, a.last_name, a.show_full_name
		ORDER BY total_coins DESC
		LIMIT $2
	`

	rows, err := r.pool.Query(ctx, query, eventID, limit)
	if err != nil {
		return nil, fmt.Errorf("query leaderboard: %w", err)
	}
	defer rows.Close()

	var entries []models.LeaderboardEntry

	for rows.Next() {
		var entry models.LeaderboardEntry
		var firstNameEnc, lastNameEnc string

		if err := rows.Scan(
			&entry.UserID, &entry.TotalCoins, &firstNameEnc, &lastNameEnc, &entry.ShowFullName,
		); err != nil {
			return nil, fmt.Errorf("scan leaderboard entry: %w", err)
		}

		// Decrypt PII fields
		firstName, err := r.decrypt(firstNameEnc)
		if err != nil {
			slog.ErrorContext(ctx, "failed to decrypt leaderboard first name", "error", err)
			continue
		}
		lastName, err := r.decrypt(lastNameEnc)
		if err != nil {
			slog.ErrorContext(ctx, "failed to decrypt leaderboard last name", "error", err)
			continue
		}
		entry.FirstName = firstName
		entry.LastName = lastName

		if !entry.ShowFullName {
			if len(entry.FirstName) > 0 {
				runes := []rune(entry.FirstName)
				entry.FirstName = string(runes[0]) + "***"
			}
			if len(entry.LastName) > 0 {
				runes := []rune(entry.LastName)
				entry.LastName = string(runes[0]) + "***"
			}
		}

		entries = append(entries, entry)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

func (r *LeaderboardRepo) decrypt(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(ciphertext, r.piiKey)
	if err != nil {
		return "", fmt.Errorf("decrypting PII field: %w", err)
	}
	return plaintext, nil
}

func (r *LeaderboardRepo) GetPreferences(ctx context.Context, userUUID string) (bool, error) {
	var showFullName bool
	err := r.pool.QueryRow(ctx, "SELECT show_full_name FROM attendees WHERE idp_uuid = $1", userUUID).Scan(&showFullName)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("query leaderboard preferences: %w", err)
	}
	return showFullName, nil
}

func (r *LeaderboardRepo) UpdatePreferences(ctx context.Context, userUUID string, showFullName bool) error {
	cmdTag, err := r.pool.Exec(ctx, "UPDATE attendees SET show_full_name = $1 WHERE idp_uuid = $2", showFullName, userUUID)
	if err != nil {
		return fmt.Errorf("update leaderboard preferences: %w", err)
	}
	if cmdTag.RowsAffected() == 0 {
		return errors.New("attendee not found")
	}
	return nil
}
