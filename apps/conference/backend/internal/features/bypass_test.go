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
	"strings"
	"testing"
	"time"
)

func TestBypassListIsParsedFromSeparatorsAHumanWouldType(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []string
	}{
		{"single", "tester@wso2.com", []string{"tester@wso2.com"}},
		{"commas", "a@wso2.com,b@wso2.com", []string{"a@wso2.com", "b@wso2.com"}},
		{"commas and spaces", "a@wso2.com, b@wso2.com", []string{"a@wso2.com", "b@wso2.com"}},
		{"semicolons", "a@wso2.com; b@wso2.com", []string{"a@wso2.com", "b@wso2.com"}},
		{"newlines", "a@wso2.com\nb@wso2.com\n", []string{"a@wso2.com", "b@wso2.com"}},
		{"case folded", "Tester@WSO2.com", []string{"tester@wso2.com"}},
		{"trailing separator", "a@wso2.com,", []string{"a@wso2.com"}},
		{"empty entries dropped", "a@wso2.com,,;, ,b@wso2.com", []string{"a@wso2.com", "b@wso2.com"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseBypassEmails(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("parsed %d entries from %q, want %d: %v", len(got), tc.raw, len(tc.want), got)
			}
			for _, w := range tc.want {
				if _, ok := got[w]; !ok {
					t.Errorf("%q missing from the parsed set %v", w, got)
				}
			}
		})
	}
}

// The whole row exists to let requests through, so every way of saying
// "nothing here" must mean nobody rather than everybody.
func TestAnEmptyBypassRowAllowsNobody(t *testing.T) {
	for _, raw := range []string{"", "   ", ",", ";\n , ", "\n"} {
		if got := parseBypassEmails(raw); len(got) != 0 {
			t.Errorf("parseBypassEmails(%q) = %v, want an empty set", raw, got)
		}
	}
}

func TestBypassesGatesMatchesOnlyListedCallers(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(
		GateBypassEmailsKey, "tester@wso2.com, other@wso2.com",
	)})
	ctx := context.Background()

	for _, email := range []string{"tester@wso2.com", "TESTER@wso2.com", " tester@wso2.com "} {
		if !res.BypassesGates(ctx, email) {
			t.Errorf("BypassesGates(%q) = false, want true", email)
		}
	}
	for _, email := range []string{"attendee@example.com", "tester@wso2.com.evil.example", "tester"} {
		if res.BypassesGates(ctx, email) {
			t.Errorf("BypassesGates(%q) = true, want false", email)
		}
	}
}

// A token that verified but carried no email claim must not be handed the
// bypass, however the row is spelled.
func TestBypassesGatesDeniesAnEmptyEmail(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(GateBypassEmailsKey, ", ,tester@wso2.com")})
	for _, email := range []string{"", "   "} {
		if res.BypassesGates(context.Background(), email) {
			t.Errorf("BypassesGates(%q) = true, want false", email)
		}
	}
}

// No row, and no read at all, must both mean nobody -- there is no
// compiled-in allowlist for a default snapshot to carry.
func TestBypassIsOffWithoutARow(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows("is_agenda_enabled", "1")})
	if res.BypassesGates(context.Background(), "tester@wso2.com") {
		t.Error("a table with no bypass row must allow nobody")
	}

	failing, _ := newTestResolver(&fakeReader{err: errBoom})
	if failing.BypassesGates(context.Background(), "tester@wso2.com") {
		t.Error("a resolver that has never read app_config must allow nobody")
	}
	if len(defaultSnapshot().bypass) != 0 {
		t.Error("defaultSnapshot must not compile in an allowlist")
	}
}

// `*` is documented as not being a pattern. Assert it, because a reader who
// assumes otherwise would believe they had opened every endpoint to everyone.
func TestBypassHasNoWildcard(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(GateBypassEmailsKey, "*")})
	if res.BypassesGates(context.Background(), "anyone@example.com") {
		t.Error("`*` must be an address that matches nothing, not a wildcard")
	}
}

// Clearing the row revokes the bypass, and within the same TTL as every other
// flag -- otherwise "switch it back off" would be a redeploy.
func TestClearingTheRowRevokesTheBypassAfterTheTTL(t *testing.T) {
	reader := &fakeReader{rows: rows(GateBypassEmailsKey, "tester@wso2.com")}
	res, now := newTestResolver(reader)
	ctx := context.Background()

	if !res.BypassesGates(ctx, "tester@wso2.com") {
		t.Fatal("the listed caller should bypass to begin with")
	}

	reader.rows = rows(GateBypassEmailsKey, "")
	*now = now.Add(DefaultTTL + time.Second)

	if res.BypassesGates(ctx, "tester@wso2.com") {
		t.Error("clearing the row must revoke the bypass once the TTL lapses")
	}
}

// The allowlist row must not be mistaken for a feature the way any
// is_<x>_enabled row would be -- same trap 016 documents for is_shop_hidden.
func TestBypassRowIsNotDiscoveredAsAFeature(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(GateBypassEmailsKey, "tester@wso2.com")})

	snap := res.Snapshot(context.Background())
	if len(snap) != len(All()) {
		t.Errorf("snapshot has %d features, want the %d in the registry", len(snap), len(All()))
	}
	for f := range snap {
		if strings.Contains(string(f), "bypass") {
			t.Errorf("the allowlist row produced a feature %q", f)
		}
	}
	if _, ok := featureFromEnabledKey(GateBypassEmailsKey); ok {
		t.Errorf("featureFromEnabledKey must not match %q", GateBypassEmailsKey)
	}
}

// The gate map and the allowlist are read from one snapshot, so a row that
// sets both must not leave the two half-applied.
func TestBypassAndFlagsComeFromTheSameRead(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(
		"is_shop_enabled", "0",
		GateBypassEmailsKey, "tester@wso2.com",
	)})
	ctx := context.Background()

	if res.Enabled(ctx, Shop) {
		t.Error("is_shop_enabled=0 must still report the shop as off")
	}
	if !res.BypassesGates(ctx, "tester@wso2.com") {
		t.Error("the same read must also carry the allowlist")
	}
	if state, gated := res.Gate(ctx, "GET", "/shops/items"); !gated || state.Enabled {
		t.Errorf("the shop routes must still resolve as gated and off: gated=%v state=%+v", gated, state)
	}
}
