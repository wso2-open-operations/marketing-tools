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

package features

import (
	"context"
	"errors"
	"testing"
	"time"

	"wso2-coin-backend/internal/models"
)

var errBoom = errors.New("boom")

// fakeReader counts calls so the TTL tests can assert that the cache actually
// prevents a query rather than merely returning the right answer.
type fakeReader struct {
	rows  []models.AppConfig
	err   error
	calls int
}

func (f *fakeReader) List(context.Context) ([]models.AppConfig, error) {
	f.calls++
	return f.rows, f.err
}

func rows(kv ...string) []models.AppConfig {
	if len(kv)%2 != 0 {
		panic("rows: want key/value pairs")
	}
	out := make([]models.AppConfig, 0, len(kv)/2)
	for i := 0; i < len(kv); i += 2 {
		out = append(out, models.AppConfig{Key: kv[i], Value: kv[i+1]})
	}
	return out
}

func newTestResolver(r ConfigReader) (*Resolver, *time.Time) {
	now := time.Now()
	res := NewResolver(r)
	res.now = func() time.Time { return now }
	return res, &now
}

func TestKeysUseTheExistingSpelling(t *testing.T) {
	// These four keys already exist in production. Renaming them orphans
	// live rows, so pin the spelling.
	if got := Agenda.EnabledKey(); got != "is_agenda_enabled" {
		t.Errorf("EnabledKey() = %q", got)
	}
	if got := AIChat.EnabledKey(); got != "is_ai_chat_enabled" {
		t.Errorf("EnabledKey() = %q", got)
	}
	if got := Networking.TitleKey(); got != "networking_coming_soon_title" {
		t.Errorf("TitleKey() = %q", got)
	}
	if got := Speakers.MessageKey(); got != "speakers_coming_soon_message" {
		t.Errorf("MessageKey() = %q", got)
	}
}

func TestDefaultsCloseAIAndNetworkingOnly(t *testing.T) {
	offByDefault := map[Feature]bool{
		AgendaRecommendations:   true,
		AttendeeRecommendations: true,
		AIChat:                  true,
		O2Bar:                   true,
		PersonalizedProfile:     true,
		Networking:              true,
	}

	for _, d := range All() {
		wantOff := offByDefault[d.Feature]
		if d.EnabledByDefault == wantOff {
			t.Errorf("%s: EnabledByDefault = %v, want %v", d.Feature, d.EnabledByDefault, !wantOff)
		}
		if d.DefaultTitle == "" || d.DefaultMessage == "" {
			t.Errorf("%s: placeholder copy is incomplete", d.Feature)
		}
	}
}

func TestResolverFallsBackToDefaultsBeforeAnySuccessfulRead(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{err: errBoom})
	ctx := context.Background()

	if !res.Enabled(ctx, Agenda) {
		t.Error("agenda should default on when app_config cannot be read")
	}
	if res.Enabled(ctx, AIChat) {
		t.Error("ai_chat should default off when app_config cannot be read")
	}
	if got := res.State(ctx, Networking).Title; got != "Networking is coming soon" {
		t.Errorf("Title = %q, want the compiled-in default", got)
	}
}

func TestRowsOverrideDefaults(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(
		"is_agenda_enabled", "0",
		"is_ai_chat_enabled", "1",
		"agenda_coming_soon_title", "Back on Monday",
		"agenda_coming_soon_message", "We are rebuilding the schedule.",
	)})
	ctx := context.Background()

	if res.Enabled(ctx, Agenda) {
		t.Error("is_agenda_enabled=0 should switch agenda off")
	}
	if !res.Enabled(ctx, AIChat) {
		t.Error("is_ai_chat_enabled=1 should switch ai_chat on despite the default")
	}
	got := res.State(ctx, Agenda)
	if got.Title != "Back on Monday" || got.Message != "We are rebuilding the schedule." {
		t.Errorf("copy not overridden: %+v", got)
	}
}

func TestUnparseableAndBlankRowsKeepTheDefault(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(
		// A typo must not take a live screen offline.
		"is_agenda_enabled", "yes please",
		// Blanking copy restores the default rather than rendering an
		// empty placeholder.
		"agenda_coming_soon_title", "   ",
	)})
	ctx := context.Background()

	got := res.State(ctx, Agenda)
	if !got.Enabled {
		t.Error("an unparseable value should leave the default in place, not disable the feature")
	}
	if got.Title != "Agenda coming soon" {
		t.Errorf("Title = %q, want the compiled-in default", got.Title)
	}
}

func TestWordFormsAreAccepted(t *testing.T) {
	for _, v := range []string{"true", "TRUE", "Yes", "on"} {
		res, _ := newTestResolver(&fakeReader{rows: rows("is_ai_chat_enabled", v)})
		if !res.Enabled(context.Background(), AIChat) {
			t.Errorf("%q should read as enabled", v)
		}
	}
	for _, v := range []string{"0", "false", "No", "OFF"} {
		res, _ := newTestResolver(&fakeReader{rows: rows("is_agenda_enabled", v)})
		if res.Enabled(context.Background(), Agenda) {
			t.Errorf("%q should read as disabled", v)
		}
	}
}

// The point of the whole design: a feature nobody compiled in still works.
func TestFeatureAddedOnlyInTheDatabaseIsHonoured(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(
		"is_scavenger_hunt_enabled", "0",
		"scavenger_hunt_coming_soon_title", "Hunt starts Tuesday",
		"scavenger_hunt_coming_soon_message", "Grab your first clue at the keynote.",
		GateMapKey, `{"scavenger_hunt": ["GET /activities"]}`,
	)})
	ctx := context.Background()

	got := res.State(ctx, Feature("scavenger_hunt"))
	if got.Enabled {
		t.Error("a database-only feature should honour its own row")
	}
	if got.Title != "Hunt starts Tuesday" {
		t.Errorf("Title = %q, want the row's value", got.Title)
	}

	state, gated := res.Gate(ctx, "GET", "/activities")
	if !gated || state.Feature != "scavenger_hunt" || state.Enabled {
		t.Errorf("Gate() = %+v, %v; want the database-only feature to govern the route", state, gated)
	}
}

func TestUnknownFeatureFailsOpen(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows("is_agenda_enabled", "1")})
	if !res.Enabled(context.Background(), Feature("typo_in_route_wiring")) {
		t.Error("an unknown feature must fail open, not take an endpoint offline")
	}
}

func TestSnapshotIsCachedForTheTTLAndThenRefetched(t *testing.T) {
	reader := &fakeReader{rows: rows("is_agenda_enabled", "1")}
	res, now := newTestResolver(reader)
	ctx := context.Background()

	res.Enabled(ctx, Agenda)
	res.Enabled(ctx, Speakers)
	res.Enabled(ctx, Shop)
	if reader.calls != 1 {
		t.Fatalf("calls = %d, want 1 read shared by every lookup", reader.calls)
	}

	*now = now.Add(DefaultTTL + time.Second)
	reader.rows = rows("is_agenda_enabled", "0")
	if res.Enabled(ctx, Agenda) {
		t.Error("a toggle should take effect once the TTL has elapsed")
	}
	if reader.calls != 2 {
		t.Errorf("calls = %d, want a single refetch after the TTL", reader.calls)
	}
}

func TestAFailedRefreshKeepsTheLastGoodAnswer(t *testing.T) {
	reader := &fakeReader{rows: rows("is_agenda_enabled", "0")}
	res, now := newTestResolver(reader)
	ctx := context.Background()

	if res.Enabled(ctx, Agenda) {
		t.Fatal("precondition: agenda should be off")
	}

	*now = now.Add(DefaultTTL + time.Second)
	reader.err = errBoom
	if res.Enabled(ctx, Agenda) {
		t.Error("a database failure should keep the last known configuration, not revert to the default")
	}
}

func TestARefreshFailureIsNotCached(t *testing.T) {
	reader := &fakeReader{err: errBoom}
	res, _ := newTestResolver(reader)
	ctx := context.Background()

	res.Enabled(ctx, Agenda)
	res.Enabled(ctx, Agenda)
	if reader.calls != 2 {
		t.Errorf("calls = %d, want the next request to retry rather than wait out a TTL", reader.calls)
	}
}

// A cancelled request must not stop the shared snapshot being populated.
func TestRefreshSurvivesACancelledRequestContext(t *testing.T) {
	reader := &fakeReader{rows: rows("is_agenda_enabled", "0")}
	res, _ := newTestResolver(reader)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if res.Enabled(ctx, Agenda) {
		t.Error("the refresh should have completed on a detached context")
	}
}
