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
	"encoding/json"
	"strings"
)

// GateMapKey is the app_config row that says which routes belong to which
// feature.
//
// It is data, not code, for one reason: a feature flag whose enforcement lives
// in a compiled route table means every new feature needs a backend release
// before it can be switched off, which defeats the point of a database
// toggle. With the mapping in a row, adding a feature is an INSERT and
// re-pointing a route is an UPDATE.
//
// The value is a JSON object of feature name to route patterns:
//
//	{
//	  "agenda":   ["GET /event-agendas", "GET /events"],
//	  "speakers": ["GET /speakers"]
//	}
//
// Each pattern is "<METHOD> <gin route pattern>" -- the pattern exactly as
// registered in cmd/server/main.go, wildcards and all ("GET
// /events/:eventId/agendas"), because that is what gin reports as
// c.FullPath(). A method of "*" matches any verb.
const GateMapKey = "feature_gates"

// GateMap answers "which feature governs this route", keyed by
// "<METHOD> <route pattern>".
type GateMap map[string]Feature

// normaliseRoutePattern canonicalises one "<METHOD> <path>" pattern so that
// hand-edited rows match regardless of spacing or verb case. A pattern with no
// space is treated as a path with a "*" method, so "/speakers" gates every
// verb on /speakers.
func normaliseRoutePattern(pattern string) (string, bool) {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		return "", false
	}

	method, path, found := strings.Cut(pattern, " ")
	if !found {
		method, path = "*", pattern
	}

	method = strings.ToUpper(strings.TrimSpace(method))
	path = strings.TrimSpace(path)
	if path == "" {
		return "", false
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return method + " " + path, true
}

// parseGateMap turns the stored JSON into a lookup keyed by route. An
// unparseable value yields ok=false so the caller can keep the previous map
// rather than un-gating the whole API on a typo.
func parseGateMap(raw string) (GateMap, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, false
	}

	var byFeature map[string][]string
	if err := json.Unmarshal([]byte(raw), &byFeature); err != nil {
		return nil, false
	}

	out := make(GateMap)
	for name, patterns := range byFeature {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		for _, p := range patterns {
			if key, ok := normaliseRoutePattern(p); ok {
				out[key] = Feature(name)
			}
		}
	}
	return out, true
}

// Feature returns the feature governing method+path, if any. An exact
// "<METHOD> <path>" entry wins over a "*" entry for the same path, so a row
// can gate the whole resource and then carve out one verb.
func (g GateMap) Feature(method, routePattern string) (Feature, bool) {
	if len(g) == 0 || routePattern == "" {
		return "", false
	}
	if f, ok := g[strings.ToUpper(method)+" "+routePattern]; ok {
		return f, true
	}
	f, ok := g["* "+routePattern]
	return f, ok
}

// DefaultGateMap is the mapping this build ships with. It is the bootstrap
// value only: migrations/015 seeds the same content into app_config, and once
// that row exists it wins outright. Its real job is to keep a database that is
// behind on migrations -- or one where somebody deleted the row -- gating the
// same routes this build was tested against, rather than silently serving
// every disabled feature.
//
// Deliberately absent: /events/current, /attendees, /attendees/me,
// /user-profile and /app-configs. Those are how the shell learns who is
// holding the phone and which event is running; gating them turns a hidden
// screen into a broken app. If you decide otherwise, it is an UPDATE to the
// row, not a code change -- which is the point.
func DefaultGateMap() GateMap {
	return mustParseGateMap(DefaultGateMapJSON)
}

// DefaultGateMapJSON is DefaultGateMap in the wire format, exported so the
// migration and the tests can assert on the same bytes this build compiles in.
const DefaultGateMapJSON = `{
  "agenda": ["GET /event-agendas", "GET /events", "GET /events/:eventId/agendas"],
  "session_details": ["GET /sessions/:id", "GET /sessions/current"],
  "speakers": ["GET /speakers"],
  "speaker_details": ["GET /speakers/:id"],
  "agenda_recommendations": ["GET /agenda/recommendations"],
  "networking": [
    "GET /users/me/connections",
    "POST /users/me/connections",
    "POST /users/me/connections/:id/accept",
    "DELETE /users/me/connections/:id"
  ],
  "attendee_list": ["POST /attendees/search"],
  "attendee_recommendations": ["GET /users/me/matches"],
  "ai_chat": ["POST /assistant/chat", "GET /ai-maintenance-status"],
  "o2bar": ["GET /o2bar/recommendations", "POST /o2bar/recommendations"],
  "personalized_profile": ["POST /users/profile"],
  "activities": ["GET /activities"],
  "feedback": ["POST /feedback"],
  "favorites": [
    "GET /users/me/favorites",
    "PUT /users/me/favorites/:sessionId",
    "DELETE /users/me/favorites/:sessionId"
  ],
  "shop": [
    "GET /shops/items",
    "GET /shops/orders/me",
    "POST /shops/checkout",
    "POST /shops/checkout/confirm"
  ],
  "wallet": ["GET /wallets/balances/me"],
  "coin": ["POST /qr/scan", "GET /qr/history", "GET /qr/summary", "GET /qr-codes"],
  "leaderboard": [
    "GET /leaderboard",
    "GET /leaderboard/preferences",
    "PUT /leaderboard/preferences"
  ],
  "notifications": ["POST /users/notifications"]
}`

// mustParseGateMap panics on a malformed DefaultGateMapJSON. The input is a
// compile-time constant in this file, so a failure here is a typo caught by
// the package's own tests, never a runtime condition.
func mustParseGateMap(raw string) GateMap {
	g, ok := parseGateMap(raw)
	if !ok {
		panic("features: DefaultGateMapJSON is not valid JSON")
	}
	return g
}
