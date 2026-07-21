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

// Event represents a single conference, as returned by GET /events. The old
// Ballerina schema's `event` had a `location` column; the new
// conference_config table has no equivalent, so it's dropped (see
// .claude/PLAN.md). IsCurrent is computed as the config with the latest
// start_date, not a stored column.
type Event struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	IsCurrent bool   `json:"isCurrent"`
}

// EventAgenda represents a single conference day and its scheduled sessions,
// as returned by GET /events/:eventId/agendas and GET /event-agendas. Maps to
// the old Ballerina `AgendaInfo` (backed by the `agenda` table), now backed by
// conference_days. Sessions reuse the bare Session type as-is -- no
// location/venue/sessionSpeakers/sessionSponsors embeds, per user decision
// 2026-07-20 (see .claude/PLAN.md).
type EventAgenda struct {
	ID       string    `json:"id"`
	EventID  string    `json:"eventId"`
	Name     string    `json:"name,omitempty"`
	Date     string    `json:"date"`
	Sessions []Session `json:"sessions"`
}
