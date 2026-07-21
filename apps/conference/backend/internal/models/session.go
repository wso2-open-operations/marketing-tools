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

// Session represents a single conference agenda item, as returned by
// GET /sessions/:id. The old Ballerina schema stored startTime/endTime as
// strings and had youtubeLink/slidesLink/pdfLink/locationId/venueId/agendaId;
// the new marketingops.sessions table computes time from a day+slot instead,
// has no venue/agenda concept, and models links as two generic labeled
// slots. See .claude/PLAN.md for the full field-by-field mapping.
type Session struct {
	ID            string     `json:"id"`
	Kind          string     `json:"kind"`
	Title         string     `json:"title"`
	Description   string     `json:"description"`
	Category      string     `json:"category,omitempty"`
	StartTime     *time.Time `json:"startTime,omitempty"`
	EndTime       *time.Time `json:"endTime,omitempty"`
	DayID         string     `json:"dayId,omitempty"`
	TrackID       string     `json:"trackId,omitempty"`
	SlotIndex     *int       `json:"slotIndex,omitempty"`
	DurationSlots int        `json:"durationSlots"`
	RoomID        string     `json:"roomId,omitempty"`
	ArticleURL    string     `json:"articleUrl,omitempty"`
	ArticleLabel  string     `json:"articleLabel,omitempty"`
	VideoURL      string     `json:"videoUrl,omitempty"`
	VideoLabel    string     `json:"videoLabel,omitempty"`
}

// SessionPresenters represents one entry of GET /sessions/current: a
// session's id, title (as name, matching the old Ballerina field name), and
// the plaintext names of every speaker attached to it.
type SessionPresenters struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Presenters []string `json:"presenters"`
}
