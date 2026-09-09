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
	"strings"
	"testing"
)

// Colour resolution is read-time SQL now
// (COALESCE(rooms.color_token, tracks.color_token, 'main')), so what there is
// to test without a database is the expression that gets built: that it puts
// the room ahead of the track, that it always ends in the default, and that it
// names no column the database might not have. The resolution itself is
// exercised end-to-end by the integration tests in session_test.go and
// event_test.go.
func TestColorTokenExpr(t *testing.T) {
	tests := []struct {
		name        string
		room, track bool
		want        string
	}{
		{
			// Upstream 027 applied: the room owns the colour, the track is the
			// fallback for tracks with no room, 'main' closes the chain.
			name: "both columns present resolves room then track then default",
			room: true, track: true,
			want: "COALESCE(r.color_token, t.color_token, 'main')",
		},
		{
			// Half-applied 027 (the two ALTERs run separately). Whichever
			// column is there is still worth reading; the other simply drops
			// out of the chain rather than taking the query down with it.
			name: "rooms only still resolves the room colour",
			room: true,
			want: "COALESCE(r.color_token, 'main')",
		},
		{
			name:  "tracks only still resolves the track colour",
			track: true,
			want:  "COALESCE(t.color_token, 'main')",
		},
		{
			// The fallback that matters: a database below upstream 027, or a
			// probe that could not be answered. Naming color_token here would
			// 500 every session, speaker and agenda read.
			name: "neither column degrades to the default token",
			want: "'main'::text",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorTokenExpr(tt.room, tt.track)
			if got != tt.want {
				t.Errorf("colorTokenExpr(%v, %v) = %q, want %q", tt.room, tt.track, got, tt.want)
			}
			if !strings.Contains(got, ColorTokenDefault) {
				t.Errorf("%q does not fall back to ColorTokenDefault %q", got, ColorTokenDefault)
			}
			if !tt.room && strings.Contains(got, "r.color_token") {
				t.Errorf("%q reads rooms.color_token, which the database does not have", got)
			}
			if !tt.track && strings.Contains(got, "t.color_token") {
				t.Errorf("%q reads tracks.color_token, which the database does not have", got)
			}
		})
	}
}

// The room must come first in the COALESCE. A room is the stable, event-long
// thing an attendee navigates by; a track is one column on one day, and most
// keynotes and every break sit on no track at all. Getting this backwards would
// let a track override the room colour for exactly the sessions that have both.
func TestColorTokenExprPrefersRoomOverTrack(t *testing.T) {
	expr := colorTokenExpr(true, true)
	room := strings.Index(expr, "r.color_token")
	track := strings.Index(expr, "t.color_token")
	if room < 0 || track < 0 {
		t.Fatalf("expression %q does not read both columns", expr)
	}
	if room > track {
		t.Errorf("expression %q reads tracks before rooms; the room owns the colour", expr)
	}
	if !strings.HasSuffix(expr, "'main')") {
		t.Errorf("expression %q does not end in the default token", expr)
	}
}

// A resolved capability is answered from the cache, never re-probed -- which is
// what lets the queries call this once per request without a round trip. Passing
// a nil pool makes that concrete: a probe here would panic.
func TestColorTokenSQLUsesTheCachedCapability(t *testing.T) {
	tests := []struct {
		name        string
		room, track bool
	}{
		{"both present", true, true},
		{"neither present", false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			caps := &schemaCaps{colorResolved: true, hasRoomColorToken: tt.room, hasTrackColorToken: tt.track}
			if got, want := caps.colorTokenSQL(context.Background(), nil), colorTokenExpr(tt.room, tt.track); got != want {
				t.Errorf("colorTokenSQL = %q, want %q", got, want)
			}
		})
	}
}

// Every token this backend can emit must be in the published set, or a client
// generating an enum from the openapi spec gets a value it can't handle. The
// set is also the upstream CHECK constraint on rooms/tracks.color_token
// (agenda-organizer migration 027) -- a token the database accepts and this
// list omits would reach a client unannounced.
func TestColorTokensMatchThePublishedSet(t *testing.T) {
	want := []string{"red", "orange", "yellow", "green", "blue", "purple", "dark-blue", "main"}
	if len(ColorTokens) != len(want) {
		t.Fatalf("ColorTokens = %v, want %v", ColorTokens, want)
	}
	for i, tok := range want {
		if ColorTokens[i] != tok {
			t.Errorf("ColorTokens[%d] = %q, want %q", i, ColorTokens[i], tok)
		}
	}

	published := make(map[string]bool, len(ColorTokens))
	for _, tok := range ColorTokens {
		published[tok] = true
	}
	if !published[ColorTokenDefault] {
		t.Errorf("ColorTokenDefault %q is not in ColorTokens %v", ColorTokenDefault, ColorTokens)
	}
}
