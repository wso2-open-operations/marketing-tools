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

// Speaker is a speaker's full profile, as returned by GET /speakers/:id.
// Everything the speaker detail screen renders is here, including the
// speaker's sessions, so the client fetches one document per screen instead
// of joining the speaker list against the agenda itself.
//
// The old Ballerina schema had a separate email and description column; the
// new marketingops.speakers table has neither, so email is dropped and
// Description is populated from the new schema's title column instead (see
// .claude/PLAN.md).
type Speaker struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Bio         string `json:"bio"`
	PhotoURL    string `json:"photoUrl"`
	// Sessions the speaker is on in the current conference, resolved
	// server-side. Always an array, never null.
	Sessions []SpeakerSession `json:"sessions"`
}

// SpeakerSession is a session embedded on a Speaker, resolved server-side
// (title + real times) so the speaker detail screen renders without a client
// join back to the sessions it only had ids for (FE.md 3.2). Replaces the old
// bare {speakerId, sessionId, eventId} reference shape.
type SpeakerSession struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	StartTime *time.Time `json:"startTime,omitempty"`
	EndTime   *time.Time `json:"endTime,omitempty"`
	// RoomName mirrors Session.RoomName so a speaker's session list renders the
	// same room label as the agenda, without a second fetch. Omitted when the
	// session has no room.
	RoomName string `json:"roomName,omitempty"`
	// ColorToken mirrors Session.ColorToken: the name of the session's colour
	// for a client that owns the values per light/dark appearance, resolved by
	// the same room -> track -> "main" chain, so this screen and the agenda
	// agree on a session's colour. Always present, defaulting to
	// repository.ColorTokenDefault.
	ColorToken string `json:"colorToken"`
}

// SpeakerSummary represents one entry of GET /speakers: what a row in the
// speaker directory renders, and nothing else.
//
// It deliberately carries no sessions. The list screen never draws them, and
// embedding them here is what pushed clients into holding the whole speaker
// list in memory just to enrich a single speaker later. A client that needs a
// speaker's sessions fetches GET /speakers/:id.
type SpeakerSummary struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Bio         string `json:"bio"`
	PhotoURL    string `json:"photoUrl"`
}

// SpeakerFilter narrows GET /speakers server-side so the client stops
// over-fetching and filtering in the browser (FE.md 3.3, .claude/PLAN.md
// Phase B). An empty field means "no filter on that axis".
type SpeakerFilter struct {
	// EventID restricts to speakers with at least one session in this
	// conference_config id (and shows only those sessions).
	EventID string
	// Query is a case-insensitive substring match over the (decrypted) speaker
	// name, title and company -- a directory search for "wso2" has to find the
	// people who work there. Matched in Go, not SQL: all three columns are
	// encrypted at rest, so an SQL ILIKE over the ciphertext is meaningless.
	Query string
}
