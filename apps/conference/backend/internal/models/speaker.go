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

package models

import "time"

// Speaker represents a single conference speaker, as returned by
// GET /speakers/:id. The old Ballerina schema had a separate email and
// description column; the new marketingops.speakers table has neither, so
// email is dropped and Description is populated from the new schema's title
// column instead (see .claude/PLAN.md).
type Speaker struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Bio         string `json:"bio"`
	PhotoURL    string `json:"photoUrl"`
}

// SpeakerSession is a session embedded on a speaker in GET /speakers, resolved
// server-side (title + real times) so SpeakerDetails renders without a client
// join back to the sessions it only had ids for (FE.md 3.2). Replaces the old
// bare {speakerId, sessionId, eventId} reference shape.
type SpeakerSession struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	StartTime *time.Time `json:"startTime,omitempty"`
	EndTime   *time.Time `json:"endTime,omitempty"`
}

// SpeakerSummary represents one entry of GET /speakers, with each session the
// speaker is attached to embedded as a resolved SpeakerSession.
type SpeakerSummary struct {
	ID          string           `json:"id"`
	Name        string           `json:"name"`
	Description string           `json:"description,omitempty"`
	Bio         string           `json:"bio"`
	PhotoURL    string           `json:"photoUrl"`
	Sessions    []SpeakerSession `json:"sessions"`
}

// SpeakerFilter narrows GET /speakers server-side so the client stops
// over-fetching and filtering in the browser (FE.md 3.3, .claude/PLAN.md
// Phase B). An empty field means "no filter on that axis".
type SpeakerFilter struct {
	// EventID restricts to speakers with at least one session in this
	// conference_config id (and shows only those sessions).
	EventID string
	// Query is a case-insensitive substring match on the (decrypted) speaker
	// name. Matched in Go, not SQL: name is encrypted at rest, so an SQL ILIKE
	// over the ciphertext is meaningless.
	Query string
}
