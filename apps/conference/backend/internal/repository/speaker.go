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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// SpeakerRepo provides read access to the speakers/session_speakers tables.
// name/title/bio are encrypted at rest (see internal/crypto); piiKey decrypts
// them on read.
type SpeakerRepo struct {
	pool   *pgxpool.Pool
	piiKey []byte
}

// NewSpeakerRepo constructs a SpeakerRepo backed by the given pool, decrypting
// PII fields with piiKey (see config.Config.PIIEncryptionKey).
func NewSpeakerRepo(pool *pgxpool.Pool, piiKey []byte) *SpeakerRepo {
	return &SpeakerRepo{pool: pool, piiKey: piiKey}
}

// GetSpeaker returns a single visible speaker by id. Unlike the old Ballerina
// getSpeaker(id), this filters on visible = true: visible is a new access
// boundary the old schema never had, and this route is public/unauthenticated,
// so a hidden speaker's id must not be a back door around the same
// visibility check GetSpeakerSummary enforces. Returns ErrNotFound if no
// matching visible row exists.
func (r *SpeakerRepo) GetSpeaker(ctx context.Context, id string) (models.Speaker, error) {
	var speaker models.Speaker
	var name, title, bio string
	var photoURL *string

	err := r.pool.QueryRow(ctx,
		"SELECT id, name, title, bio, photo_url FROM speakers WHERE id = $1 AND visible",
		id,
	).Scan(&speaker.ID, &name, &title, &bio, &photoURL)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return models.Speaker{}, ErrNotFound
		}
		return models.Speaker{}, err
	}

	if speaker.Name, err = r.decrypt(name); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting name: %w", err)
	}
	if speaker.Description, err = r.decrypt(title); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting title: %w", err)
	}
	if speaker.Bio, err = r.decrypt(bio); err != nil {
		return models.Speaker{}, fmt.Errorf("decrypting bio: %w", err)
	}
	if photoURL != nil {
		speaker.PhotoURL = *photoURL
	}

	return speaker, nil
}

// GetSpeakerSummary returns every speaker with visible = true, each with the
// full list of sessions they're attached to. A speaker with no sessions still
// appears, with an empty (never nil) SessionSpeakers slice.
func (r *SpeakerRepo) GetSpeakerSummary(ctx context.Context) ([]models.SpeakerSummary, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT sp.id, sp.name, sp.title, sp.bio, sp.photo_url, ss.session_id, s.config_id
		 FROM speakers sp
		 LEFT JOIN session_speakers ss ON ss.speaker_id = sp.id
		 LEFT JOIN sessions s ON s.id = ss.session_id
		 WHERE sp.visible
		 ORDER BY sp.id`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	bySpeaker := make(map[string]*models.SpeakerSummary)

	for rows.Next() {
		var id, name, title, bio string
		var photoURL, sessionID, configID *string

		if err := rows.Scan(&id, &name, &title, &bio, &photoURL, &sessionID, &configID); err != nil {
			return nil, err
		}

		summary, ok := bySpeaker[id]
		if !ok {
			decryptedName, err := r.decrypt(name)
			if err != nil {
				return nil, fmt.Errorf("decrypting name: %w", err)
			}
			decryptedTitle, err := r.decrypt(title)
			if err != nil {
				return nil, fmt.Errorf("decrypting title: %w", err)
			}
			decryptedBio, err := r.decrypt(bio)
			if err != nil {
				return nil, fmt.Errorf("decrypting bio: %w", err)
			}

			summary = &models.SpeakerSummary{
				ID:              id,
				Name:            decryptedName,
				Description:     decryptedTitle,
				Bio:             decryptedBio,
				SessionSpeakers: make([]models.SessionSpeakerWithEvent, 0),
			}
			if photoURL != nil {
				summary.PhotoURL = *photoURL
			}
			bySpeaker[id] = summary
			order = append(order, id)
		}

		if sessionID != nil && configID != nil {
			summary.SessionSpeakers = append(summary.SessionSpeakers, models.SessionSpeakerWithEvent{
				SpeakerID: id,
				SessionID: *sessionID,
				EventID:   *configID,
			})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	summaries := make([]models.SpeakerSummary, 0, len(order))
	for _, id := range order {
		summaries = append(summaries, *bySpeaker[id])
	}
	return summaries, nil
}

func (r *SpeakerRepo) decrypt(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(ciphertext, r.piiKey)
	if err != nil {
		return "", fmt.Errorf("repository: decrypting PII field: %w", err)
	}
	return plaintext, nil
}
