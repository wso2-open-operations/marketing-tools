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

package middleware

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/features"
)

// stubGate answers from a fixed table keyed by "<METHOD> <route>".
type stubGate map[string]features.State

func (s stubGate) Gate(_ context.Context, method, routePattern string) (features.State, bool) {
	st, ok := s[method+" "+routePattern]
	return st, ok
}

func newFeatureTestRouter(t *testing.T, gate FeatureGateResolver) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(FeatureGate(gate))
	handler := func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) }
	r.GET("/speakers", handler)
	r.GET("/speakers/:id", handler)
	r.GET("/events/current", handler)
	return r
}

func get(r *gin.Engine, path string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

func TestFeatureGate_DisabledFeatureIs503(t *testing.T) {
	r := newFeatureTestRouter(t, stubGate{
		"GET /speakers": {
			Feature: features.Speakers,
			Enabled: false,
			Title:   "Speakers coming soon",
			Message: "The speaker line-up is still being confirmed.",
		},
	})

	w := get(r, "/speakers")

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}

	// The body must be usable by a client that has no flags of its own.
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["feature"] != "speakers" {
		t.Errorf("feature = %q", body["feature"])
	}
	if body["title"] != "Speakers coming soon" {
		t.Errorf("title = %q", body["title"])
	}
	// `message`, not `error`: the handler-side convention in this codebase.
	if body["message"] != "The speaker line-up is still being confirmed." {
		t.Errorf("message = %q", body["message"])
	}
}

func TestFeatureGate_EnabledFeaturePassesThrough(t *testing.T) {
	r := newFeatureTestRouter(t, stubGate{
		"GET /speakers": {Feature: features.Speakers, Enabled: true},
	})

	if w := get(r, "/speakers"); w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}
}

func TestFeatureGate_UngatedRoutePassesThrough(t *testing.T) {
	// An empty mapping is the "nothing configured" case, and it must leave
	// the API exactly as it behaved before this middleware existed.
	r := newFeatureTestRouter(t, stubGate{})

	if w := get(r, "/events/current"); w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}
}

func TestFeatureGate_MatchesOnTheRoutePatternNotTheConcretePath(t *testing.T) {
	// The mapping is written against "/speakers/:id"; a request for a real
	// id must still match it.
	r := newFeatureTestRouter(t, stubGate{
		"GET /speakers/:id": {Feature: features.SpeakerDetails, Enabled: false, Message: "later"},
	})

	if w := get(r, "/speakers/abc-123"); w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	// The list route is a different pattern and must be unaffected.
	if w := get(r, "/speakers"); w.Code != http.StatusOK {
		t.Errorf("status = %d, want the sibling route untouched", w.Code)
	}
}

func TestFeatureGate_UnmatchedPathIsLeftToGin(t *testing.T) {
	// FullPath() is empty for a path no route matched. Gating it would turn
	// gin's 404 into a 503 and hide genuine wiring mistakes.
	r := newFeatureTestRouter(t, stubGate{
		"GET ": {Feature: "whatever", Enabled: false},
	})

	if w := get(r, "/nope"); w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

// A 503 from the gate must never pick up a cache validator, or a client would
// keep serving "coming soon" after the feature is switched back on.
func TestFeatureGate_RefusalIsNotGivenAnETag(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(ETag("private, max-age=60, must-revalidate"))
	r.Use(FeatureGate(stubGate{
		"GET /speakers": {Feature: features.Speakers, Enabled: false, Message: "later"},
	}))
	r.GET("/speakers", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) })

	w := get(r, "/speakers")

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d", w.Code)
	}
	if etag := w.Header().Get("ETag"); etag != "" {
		t.Errorf("ETag = %q, want none on a refusal", etag)
	}
}
