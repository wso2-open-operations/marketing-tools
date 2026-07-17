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

// SessionSpeakerWithEvent links a speaker to a session they're speaking at.
// The old Ballerina sessionspeaker row had a surrogate int id and an eventId
// via a since-removed event table; the new schema's session_speakers has a
// composite (session_id, speaker_id) primary key with no surrogate id, so
// EventID is populated from the owning session's config_id instead.
type SessionSpeakerWithEvent struct {
	SpeakerID string `json:"speakerId"`
	SessionID string `json:"sessionId"`
	EventID   string `json:"eventId"`
}

// SpeakerSummary represents one entry of GET /speakers, including every
// session the speaker is attached to.
type SpeakerSummary struct {
	ID              string                    `json:"id"`
	Name            string                    `json:"name"`
	Description     string                    `json:"description,omitempty"`
	Bio             string                    `json:"bio"`
	PhotoURL        string                    `json:"photoUrl"`
	SessionSpeakers []SessionSpeakerWithEvent `json:"sessionSpeakers"`
}
