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

// Colour vocabulary for a session, shared by every read that publishes a
// Session/SpeakerSession colour.
//
// One field reaches a client: colorToken -- a name from a small closed set
// ("red", "main", …). It says *which* colour the session is and nothing about
// what that colour looks like, so the app owns the eight values and can define
// a different one per light/dark appearance. A hex cannot do that: it is one
// fixed value the client has no licence to reinterpret, which is why the
// trackColor/roomColor hex fields this replaced could never theme, and why they
// are gone rather than kept alongside.
//
// Resolution is read-time and lives in SQL, not in Go:
//
//	COALESCE(rooms.color_token, tracks.color_token, 'main')
//
// The colour belongs to the room -- the stable, event-long thing an attendee
// navigates by -- with the track as the fallback for tracks that have no room;
// upstream migration 027 states that ordering and constrains both columns to
// the set below. Nothing is stored per session, so there is nothing here to
// keep in step with anything.
//
// What used to live in this file -- a hex chain (tracks.color -> the
// room_colors overlay -> a per-kind fallback) and a hex->token map -- existed
// only because tracks.color_id was NULL on every live row, leaving no way to
// name a colour except by recognising its hex. Upstream 027 moves that
// derivation to where the colour is actually chosen, so both the chain and the
// room_colors overlay (migration 010, dropped in 012) are deleted rather than
// migrated.
//
// The columns the COALESCE reads are added by an upstream migration applied by
// hand, so the SELECT expression is built by schemaCaps.colorTokenSQL rather
// than hardcoded: against a database below upstream 027 it degrades to the
// literal ColorTokenDefault instead of naming a column that isn't there. See
// schema.go.

// ColorTokenDefault is what a session with no resolvable colour gets. It is the
// app's existing grey fallback, so an unthemed or unknown session lands where
// it already landed rather than somewhere new, and it is the last arm of the
// COALESCE -- so the field is always present and always safe to index a
// client-side map with.
const ColorTokenDefault = "main"

// ColorTokens is the closed set a client has to handle. The vocabulary is the
// microapp's own: these are the keys of its ROOM_COLOR_MAP (src/utils/color.ts)
// and the names in its Tailwind theme, several of which already carry a
// dark-mode shade (green.700, red.700), so a token needs no new CSS on the
// client.
//
// Published as the openapi enum for Session.colorToken and
// SpeakerSession.colorToken, and mirrored by the CHECK constraints on
// rooms.color_token / tracks.color_token -- originally upstream 027's seven,
// widened to eight by upstream 030; keep all three in step.
//
// "orange" is the one name that is not from the microapp's original map. It was
// added for WSO2Con Hollywood's "Orange Room", whose 16 sessions had been
// squatting on "red" because no closer name existed -- and Hollywood also has a
// separate Yellow Room, so neither neighbour was free to borrow. Ordered here by
// hue rather than alphabetically, so the slice reads as a spectrum with the
// achromatic default last.
var ColorTokens = []string{"red", "orange", "yellow", "green", "blue", "purple", "dark-blue", "main"}
