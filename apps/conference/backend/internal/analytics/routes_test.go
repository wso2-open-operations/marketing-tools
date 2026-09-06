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

import "testing"

func TestDefaultRoutePolicy_Lookup(t *testing.T) {
	policy := DefaultRoutePolicy()

	tests := []struct {
		name        string
		method      string
		route       string
		wantTracked bool
		wantFeature string
		wantClass   Class
	}{
		{
			name:   "health probe is skipped",
			method: "GET", route: "/health",
			wantTracked: false,
		},
		{
			// The two 5-second pollers. If these ever start being recorded they
			// will outnumber every other event by roughly 100:1.
			name:   "qr history poll is skipped",
			method: "GET", route: "/qr/history",
			wantTracked: false,
		},
		{
			name:   "qr summary poll is skipped",
			method: "GET", route: "/qr/summary",
			wantTracked: false,
		},
		{
			name:   "shop catalog poll is skipped",
			method: "GET", route: "/shops/items",
			wantTracked: false,
		},
		{
			name:   "wallet balance poll is skipped",
			method: "GET", route: "/wallets/balances/me",
			wantTracked: false,
		},
		{
			name:   "freshness beacon poll is skipped",
			method: "GET", route: "/app-configs",
			wantTracked: false,
		},
		{
			// The sibling POST must survive the GETs being skipped: it is the
			// only coin-earning signal there is.
			name:   "qr scan is intent despite its polled siblings",
			method: "POST", route: "/qr/scan",
			wantTracked: true, wantFeature: FeatureCoin, wantClass: ClassIntent,
		},
		{
			name:   "chat is intent",
			method: "POST", route: "/assistant/chat",
			wantTracked: true, wantFeature: FeatureAIAgent, wantClass: ClassIntent,
		},
		{
			// The bulk agenda fetch is kept, but classified as a screen open
			// rather than as engagement -- that distinction is the reason it can
			// be kept at all.
			name:   "bulk agenda fetch is a screen open",
			method: "GET", route: "/event-agendas",
			wantTracked: true, wantFeature: FeatureAgenda, wantClass: ClassScreen,
		},
		{
			name:   "session detail is intent",
			method: "GET", route: "/sessions/:id",
			wantTracked: true, wantFeature: FeatureAgenda, wantClass: ClassIntent,
		},
		{
			name:   "speaker list is a screen open",
			method: "GET", route: "/speakers",
			wantTracked: true, wantFeature: FeatureSpeakers, wantClass: ClassScreen,
		},
		{
			name:   "speaker detail is intent",
			method: "GET", route: "/speakers/:id",
			wantTracked: true, wantFeature: FeatureSpeakers, wantClass: ClassIntent,
		},
		{
			name:   "own profile is the kept heartbeat",
			method: "GET", route: "/attendees/me",
			wantTracked: true, wantFeature: FeatureAttendees, wantClass: ClassHeartbeat,
		},
		{
			// Method matters: the same path is a screen open on GET and an
			// action on POST.
			name:   "connections get is a screen open",
			method: "GET", route: "/users/me/connections",
			wantTracked: true, wantFeature: FeatureNetworking, wantClass: ClassScreen,
		},
		{
			name:   "connections post is intent",
			method: "POST", route: "/users/me/connections",
			wantTracked: true, wantFeature: FeatureNetworking, wantClass: ClassIntent,
		},
		{
			// A route nobody has classified is still recorded. The tag is the
			// reminder to come back and classify it.
			name:   "unknown route is tracked as unclassified",
			method: "GET", route: "/some/route/added/later",
			wantTracked: true, wantFeature: "", wantClass: ClassUnclassified,
		},
		{
			// No route matched at all: internet background noise against a
			// public endpoint.
			name:   "unmatched request is skipped",
			method: "GET", route: "",
			wantTracked: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info, tracked := policy.Lookup(tt.method, tt.route)
			if tracked != tt.wantTracked {
				t.Fatalf("Lookup(%q, %q) tracked = %v, want %v", tt.method, tt.route, tracked, tt.wantTracked)
			}
			if !tracked {
				return
			}
			if info.Feature != tt.wantFeature {
				t.Errorf("feature = %q, want %q", info.Feature, tt.wantFeature)
			}
			if info.Class != tt.wantClass {
				t.Errorf("class = %q, want %q", info.Class, tt.wantClass)
			}
		})
	}
}

// TestRouteClasses_DoNotOverlapSkippedRoutes guards against the one edit that
// would be silently wrong: classifying a route that is also on the skip list.
// The skip list wins in Lookup, so the classification would simply never apply
// and the reader of the table would have no way to tell.
func TestRouteClasses_DoNotOverlapSkippedRoutes(t *testing.T) {
	for key := range routeClasses {
		if _, skipped := skippedRoutes[key]; skipped {
			t.Errorf("%q is both classified and skipped; the skip wins, so the classification is dead", key)
		}
	}
}

// TestRouteClasses_AreFullyPopulated stops a half-filled table entry from
// reaching Moesif as an event with a feature but no class, or vice versa.
func TestRouteClasses_AreFullyPopulated(t *testing.T) {
	valid := map[Class]bool{ClassIntent: true, ClassScreen: true, ClassHeartbeat: true}

	for key, info := range routeClasses {
		if info.Feature == "" {
			t.Errorf("%q has no feature", key)
		}
		if !valid[info.Class] {
			t.Errorf("%q has class %q, want one of intent/screen/heartbeat", key, info.Class)
		}
	}
}

func TestNewRoutePolicy_NilTablesTrackEverythingKnownNothing(t *testing.T) {
	policy := NewRoutePolicy(nil, nil)

	info, tracked := policy.Lookup("GET", "/anything")
	if !tracked {
		t.Fatal("an empty policy should track, not skip")
	}
	if info.Class != ClassUnclassified {
		t.Errorf("class = %q, want %q", info.Class, ClassUnclassified)
	}
}
