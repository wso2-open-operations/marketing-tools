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
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/crypto"
	"wso2-coin-backend/internal/models"
)

// decryptPII decrypts a PII field, treating "" as "" (no ciphertext). Shared
// by the repos that read encrypted speaker/attendee columns.
func decryptPII(ciphertext string, key []byte) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	plaintext, err := crypto.DecryptPII(ciphertext, key)
	if err != nil {
		return "", fmt.Errorf("repository: decrypting PII field: %w", err)
	}
	return plaintext, nil
}

// fetchSessionSpeakers returns the visible speakers attached to each of the
// given session ids, keyed by session id, names decrypted and each group
// sorted by name. Sessions with no visible speakers are simply absent from the
// map, so callers default to an empty slice. Hidden speakers (visible = false)
// are excluded so a session never leaks one the directory hides.
//
// Shared by SessionRepo and EventRepo so every session-producing endpoint
// embeds the identical speaker shape (see .claude/PLAN.md Phase B). IsModerator
// comes from the owned presentation_overlay table (Phase C): a LEFT JOIN, so a
// missing row means "not a moderator". This replaces the frontend's
// moderators.json.
func fetchSessionSpeakers(ctx context.Context, pool *pgxpool.Pool, piiKey []byte, sessionIDs []string) (map[string][]models.SessionSpeaker, error) {
	result := make(map[string][]models.SessionSpeaker)
	if len(sessionIDs) == 0 {
		return result, nil
	}

	rows, err := pool.Query(ctx,
		`SELECT ss.session_id, sp.id, sp.name, sp.photo_url, COALESCE(po.is_moderator, false)
		 FROM session_speakers ss
		 JOIN speakers sp ON sp.id = ss.speaker_id
		 LEFT JOIN presentation_overlay po
		        ON po.session_id = ss.session_id AND po.speaker_id = ss.speaker_id
		 WHERE ss.session_id = ANY($1) AND sp.visible`,
		sessionIDs,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var sessionID, speakerID, encName string
		var photoURL *string
		var isModerator bool
		if err := rows.Scan(&sessionID, &speakerID, &encName, &photoURL, &isModerator); err != nil {
			return nil, err
		}
		name, err := decryptPII(encName, piiKey)
		if err != nil {
			return nil, fmt.Errorf("decrypting speaker name: %w", err)
		}
		sp := models.SessionSpeaker{ID: speakerID, Name: name, IsModerator: isModerator}
		if photoURL != nil {
			sp.PhotoURL = *photoURL
		}
		result[sessionID] = append(result[sessionID], sp)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for id := range result {
		speakers := result[id]
		sort.Slice(speakers, func(i, j int) bool { return speakers[i].Name < speakers[j].Name })
	}
	return result, nil
}
