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
	ID          string     `json:"id"`
	Kind        string     `json:"kind"`
	Title       string     `json:"title"`
	Description string     `json:"description,omitempty"`
	Category    string     `json:"category,omitempty"`
	StartTime   *time.Time `json:"startTime,omitempty"`
	EndTime     *time.Time `json:"endTime,omitempty"`
	DayID       string     `json:"dayId,omitempty"`
	TrackID     string     `json:"trackId,omitempty"`
	// TrackColor is the semantic colour resolved from tracks.color (a real
	// upstream column), replacing the frontend's ROOM_COLOR_MAP string-sniffing
	// (FE.md 3.5). Omitted when the track has none.
	TrackColor    string `json:"trackColor,omitempty"`
	SlotIndex     *int   `json:"slotIndex,omitempty"`
	DurationSlots int    `json:"durationSlots"`
	RoomID        string `json:"roomId,omitempty"`
	// RoomName is resolved from rooms.name so the client renders the room label
	// without a second lookup. Omitted when the session has no room.
	RoomName     string `json:"roomName,omitempty"`
	ArticleURL   string `json:"articleUrl,omitempty"`
	ArticleLabel string `json:"articleLabel,omitempty"`
	VideoURL     string `json:"videoUrl,omitempty"`
	VideoLabel   string `json:"videoLabel,omitempty"`
	// Speakers are embedded via a server-side join so the client renders a
	// session without a second fetch or a client-side session<->speaker join
	// (FE.md 3.2). Always an array, never null. IsModerator is filled from the
	// owned presentation overlay in Phase C; it is false until then.
	Speakers []SessionSpeaker `json:"speakers"`
}

// SessionSpeaker is a speaker embedded on a Session: the minimal shape a
// session card renders. IDs are strings everywhere (FE.md 3.2 number-vs-string
// bug). Name is decrypted server-side.
type SessionSpeaker struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	PhotoURL    string `json:"photoUrl,omitempty"`
	IsModerator bool   `json:"isModerator"`
}
