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
	"testing"
)

func TestDefaultGateMapParses(t *testing.T) {
	g := DefaultGateMap()
	if len(g) == 0 {
		t.Fatal("the built-in mapping is empty")
	}
	if f, ok := g.Feature("GET", "/speakers/:id"); !ok || f != SpeakerDetails {
		t.Errorf("GET /speakers/:id -> %q, %v", f, ok)
	}
	if f, ok := g.Feature("DELETE", "/users/me/connections/:id"); !ok || f != Networking {
		t.Errorf("DELETE /users/me/connections/:id -> %q, %v", f, ok)
	}
}

// The shell must keep working with every feature switched off, so these routes
// are deliberately ungated. A change here is a product decision, not a tidy-up.
func TestShellRoutesAreNeverGated(t *testing.T) {
	g := DefaultGateMap()
	for _, route := range []struct{ method, path string }{
		{"GET", "/events/current"},
		{"GET", "/attendees/me"},
		{"GET", "/user-profile"},
		{"POST", "/attendees"},
		{"PATCH", "/attendees"},
		{"GET", "/app-configs"},
		{"GET", "/health"},
	} {
		if f, ok := g.Feature(route.method, route.path); ok {
			t.Errorf("%s %s is gated by %q; gating it breaks the app shell", route.method, route.path, f)
		}
	}
}

// Every route the built-in map names must exist in the registry, otherwise a
// disabled feature would be gated with generic copy nobody wrote.
func TestEveryGatedFeatureIsRegistered(t *testing.T) {
	for route, f := range DefaultGateMap() {
		d, ok := Lookup(f)
		if !ok {
			t.Errorf("%s is gated by %q, which is not in the registry", route, f)
			continue
		}
		if !d.Gated {
			t.Errorf("%s is gated by %q, but its registry entry says Gated: false", route, f)
		}
	}
}

// The inverse: a registry entry claiming to be gated must actually gate
// something, or the flag silently does nothing on the API side.
func TestEveryGatedRegistryEntryHasRoutes(t *testing.T) {
	covered := make(map[Feature]bool)
	for _, f := range DefaultGateMap() {
		covered[f] = true
	}
	for _, d := range All() {
		if d.Gated && !covered[d.Feature] {
			t.Errorf("%s is marked Gated but no route maps to it", d.Feature)
		}
	}
}

func TestPatternNormalisation(t *testing.T) {
	g, ok := parseGateMap(`{
	  "shop": ["  post   /shops/checkout  ", "shops/items"],
	  "coin": ["* /qr/scan"]
	}`)
	if !ok {
		t.Fatal("parse failed")
	}
	if f, ok := g.Feature("POST", "/shops/checkout"); !ok || f != Shop {
		t.Errorf("lowercase verb and stray spaces should normalise: %q %v", f, ok)
	}
	if f, ok := g.Feature("GET", "/shops/items"); !ok || f != Shop {
		t.Errorf("a bare path should gate every verb: %q %v", f, ok)
	}
	if _, ok := g.Feature("DELETE", "/qr/scan"); !ok {
		t.Error(`"*" should match any verb`)
	}
}

func TestExplicitVerbBeatsWildcard(t *testing.T) {
	g, ok := parseGateMap(`{"shop": ["* /shops/items"], "wallet": ["GET /shops/items"]}`)
	if !ok {
		t.Fatal("parse failed")
	}
	if f, _ := g.Feature("GET", "/shops/items"); f != Wallet {
		t.Errorf("GET -> %q, want the explicit entry to win", f)
	}
	if f, _ := g.Feature("POST", "/shops/items"); f != Shop {
		t.Errorf("POST -> %q, want the wildcard entry", f)
	}
}

func TestStoredMapReplacesTheBuiltInOne(t *testing.T) {
	// Replacement, not merge: un-gating a route from the database is the
	// one thing this row exists to allow, and a merge would forbid it.
	res, _ := newTestResolver(&fakeReader{rows: rows(
		GateMapKey, `{"speakers": ["GET /speakers"]}`,
	)})
	ctx := context.Background()

	if _, gated := res.Gate(ctx, "GET", "/event-agendas"); gated {
		t.Error("a route absent from the stored map should no longer be gated")
	}
	if _, gated := res.Gate(ctx, "GET", "/speakers"); !gated {
		t.Error("a route present in the stored map should be gated")
	}
}

func TestMalformedStoredMapKeepsTheBuiltInOne(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{rows: rows(GateMapKey, `{"speakers": [`)})

	if _, gated := res.Gate(context.Background(), "GET", "/event-agendas"); !gated {
		t.Error("a bad edit should degrade to the built-in mapping, not to gating nothing")
	}
}

func TestUngatedRouteIsReportedAsUngated(t *testing.T) {
	res, _ := newTestResolver(&fakeReader{})
	if _, gated := res.Gate(context.Background(), "GET", "/health"); gated {
		t.Error("/health must never be gated")
	}
}
