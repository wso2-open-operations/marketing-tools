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
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/features"
)

// FeatureGateResolver is the slice of *features.Resolver this middleware
// needs: given a matched route, which feature governs it and is that feature
// on.
type FeatureGateResolver interface {
	Gate(ctx context.Context, method, routePattern string) (features.State, bool)
	// BypassesGates reports whether this caller is on the app_config
	// allowlist (features.GateBypassEmailsKey) that is served a switched-off
	// feature anyway. Part of this interface rather than an optional one a
	// type assertion sniffs for: a resolver that cannot answer it would
	// silently take the bypass away, and the symptom -- a tester who still
	// gets 503 -- looks like a wrong row, not like missing wiring.
	BypassesGates(ctx context.Context, email string) bool
}

// FeatureGate refuses a request whose feature is switched off in app_config.
//
// The microapp already hides a disabled screen, so this is the second half of
// the same switch rather than the only one: it exists so that flipping a row
// actually stops the data flowing, instead of merely hiding the button in
// front of it. An old cached build, a deep link, or anything holding a valid
// token still gets nothing.
//
// Registered once on the authenticated group rather than per route, and the
// route-to-feature mapping is read from a database row (features.GateMapKey),
// not from this file. Both choices exist so that gating a newly added route,
// or adding a feature outright, is an UPDATE rather than a release -- a flag
// system that needs a deploy to add a flag is not much of a flag system.
//
// Ordered after Auth on purpose: which features exist is not something an
// unauthenticated caller gets to probe.
//
// A route with no entry in the mapping is untouched, so the default posture is
// "serves normally" -- the same posture as before this middleware existed.
//
// One set of callers is exempt: the addresses in
// features.GateBypassEmailsKey, which exist so that the endpoints behind an
// unannounced feature can be exercised while every microapp still hides the
// screen. The exemption is per caller, so refusing everybody else is
// unaffected, and the row is empty until an operator fills it.
//
// The response is 503, matching the shop's master-wallet gate
// (internal/handlers/shop.go) and for the same reason: nothing about the
// request is wrong, the caller cannot fix it, and it will start working again
// without a client change. 403 would claim the attendee lacks permission,
// which is not what happened, and 404 would deny a route the OpenAPI document
// still describes. The body carries the same copy the microapp would have put
// on its placeholder screen, so a client with no flags of its own still gets a
// usable message instead of a bare status. `message` (not `error`) is the
// handler-side convention in this codebase.
func FeatureGate(resolver FeatureGateResolver) gin.HandlerFunc {
	return func(c *gin.Context) {
		// FullPath is the matched route pattern ("/speakers/:id"), which is
		// what the mapping is written against. It is empty for an unmatched
		// path -- gin's own 404 handles those, and gating nothing is right.
		routePattern := c.FullPath()
		if routePattern == "" {
			c.Next()
			return
		}

		ctx := c.Request.Context()

		state, gated := resolver.Gate(ctx, c.Request.Method, routePattern)
		if !gated || state.Enabled {
			c.Next()
			return
		}

		// The allowlist is checked only once the gate has already decided to
		// refuse, so an ordinary request never pays for it and the log line
		// below is emitted only for a route that was genuinely closed.
		//
		// UserInfoFromContext is populated because this middleware is
		// registered after Auth on the same group (cmd/server/main.go); a nil
		// here means someone reordered them, and it denies rather than
		// letting an unidentified caller through.
		if user := UserInfoFromContext(ctx); user != nil && resolver.BypassesGates(ctx, user.Email) {
			// Warn, not Info: a route the operator switched off is answering,
			// which is correct here but is also the shape of a misconfigured
			// allowlist, so it should be visible without turning up the level.
			slog.WarnContext(ctx, "serving a disabled feature to an allowlisted caller",
				"feature", string(state.Feature), "method", c.Request.Method, "route", routePattern)
			c.Next()
			return
		}

		slog.InfoContext(ctx, "refusing request for a disabled feature",
			"feature", string(state.Feature), "method", c.Request.Method, "route", routePattern)

		// ETag() buffers the handler's body and only stamps a validator on
		// a 200, so this abort is never cached by a client.
		c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{
			"message": state.Message,
			"title":   state.Title,
			"feature": string(state.Feature),
		})
	}
}
