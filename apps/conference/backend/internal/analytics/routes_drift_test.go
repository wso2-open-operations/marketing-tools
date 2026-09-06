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

package analytics

import (
	"os"
	"regexp"
	"sort"
	"testing"
)

// The policy tables are keyed on route templates that have to match
// cmd/server/main.go character for character, because the lookup key is
// gin.Context.FullPath(). Nothing about that is checked by the compiler: rename
// :eventId to :eventID upstream, or add an endpoint and forget this file, and
// the only symptom is a quietly mislabelled dashboard.
//
// So these tests read main.go and compare. Reading the entrypoint from a leaf
// package's test is unusual, and the alternative was worse: building the real
// router needs a database pool and a reachable JWKS endpoint, so there is no way
// to ask Gin for its route list here. The regex is deliberately narrow and will
// stop matching if route registration ever stops being one call per line — at
// which point this test fails loudly rather than passing vacuously, which is the
// right failure mode.

const mainGoPath = "../../cmd/server/main.go"

var routeRegistration = regexp.MustCompile(`(?m)^\s*(?:api|r)\.(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\("([^"]+)"`)

// registeredRoutes returns every "METHOD /route" main.go registers.
func registeredRoutes(t *testing.T) []string {
	t.Helper()

	source, err := os.ReadFile(mainGoPath)
	if err != nil {
		t.Fatalf("reading %s: %v", mainGoPath, err)
	}

	matches := routeRegistration.FindAllStringSubmatch(string(source), -1)
	// A floor, not an exact count: the point is to catch the regex silently
	// matching nothing after a refactor, not to hard-code the route count and
	// need editing on every new endpoint.
	if len(matches) < 30 {
		t.Fatalf("found only %d route registrations in %s; the parser has probably stopped matching", len(matches), mainGoPath)
	}

	routes := make([]string, 0, len(matches))
	for _, m := range matches {
		routes = append(routes, m[1]+" "+m[2])
	}
	return routes
}

// TestPolicyCoversEveryRegisteredRoute fails when an endpoint exists that this
// package has never been told about. Such a route is still recorded — it lands
// as class=unclassified — so this is a tidiness failure rather than a data-loss
// one, but it is the moment to decide whether the new endpoint is a feature
// signal or another poller.
func TestPolicyCoversEveryRegisteredRoute(t *testing.T) {
	var missing []string

	for _, route := range registeredRoutes(t) {
		_, classified := routeClasses[route]
		_, skipped := skippedRoutes[route]
		if !classified && !skipped {
			missing = append(missing, route)
		}
	}

	sort.Strings(missing)
	for _, route := range missing {
		t.Errorf("%q is registered in main.go but is neither classified nor skipped; add it to routeClasses or skippedRoutes", route)
	}
}

// TestPolicyHasNoStaleEntries fails when a table entry names a route that no
// longer exists. A stale entry is dead weight that reads as coverage, and a
// mistyped one hides as a stale entry: this is the test that catches
// "/events/:eventID" when main.go says "/events/:eventId".
func TestPolicyHasNoStaleEntries(t *testing.T) {
	registered := map[string]struct{}{}
	for _, route := range registeredRoutes(t) {
		registered[route] = struct{}{}
	}

	var stale []string
	for route := range routeClasses {
		if _, ok := registered[route]; !ok {
			stale = append(stale, route)
		}
	}
	for route := range skippedRoutes {
		if _, ok := registered[route]; !ok {
			stale = append(stale, route)
		}
	}

	sort.Strings(stale)
	for _, route := range stale {
		t.Errorf("%q appears in the analytics route policy but is not registered in main.go; check for a typo, or drop the entry", route)
	}
}
