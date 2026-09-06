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
	"net/http"
	"net/url"
	"time"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/analytics"
)

// safeRequestHeaders is an allow list, not a deny list, and that direction is
// the whole point: a deny list has to anticipate every header that might one day
// carry a credential, and it only has to be wrong once. Notably absent are
// x-jwt-assertion (a live signed identity token, present on every authenticated
// request) and Authorization and Cookie, none of which belong in a third-party
// analytics product.
//
// What is here earns its place. Content-Type separates a JSON POST from a form
// one; User-Agent is the only device and platform breakdown available, since the
// microapp ships no client-side analytics SDK; Accept-Language is the only
// locale signal.
var safeRequestHeaders = []string{
	"Content-Type",
	"User-Agent",
	"Accept-Language",
}

// safeResponseHeaders is small on purpose. Cache-Control together with the
// response status is enough to tell a 304 revalidation apart from a delivery,
// which is the one response-side question worth asking. ETag is deliberately
// omitted: it is a hash of a body this package has decided not to send, so it
// would be an identifier for content nobody can look up.
var safeResponseHeaders = []string{
	"Content-Type",
	"Cache-Control",
}

// safeQueryParams are the query parameters whose *values* may be recorded. Every
// other parameter is recorded with its value replaced by redactedValue.
//
// This matters more than it looks. Two live query parameters carry personal
// data: GET /user-profile takes ?email=, and GET /speakers takes ?q=, whose
// value is free text an attendee typed and which in practice is a colleague's
// name. Redacting the value while keeping the key preserves the useful fact
// ("somebody ran a speaker search") and drops the sensitive one (who they
// searched for).
var safeQueryParams = map[string]struct{}{
	"eventId":   {},
	"isCurrent": {},
	"previous":  {},
	"limit":     {},
	"cursor":    {},
}

// redactedValue is what a non-allow-listed query value is replaced with. It is
// intentionally recognisable in the Moesif UI, so that a reader can tell
// "redacted here" from "the parameter was empty".
const redactedValue = "[redacted]"

// Analytics records one usage event per served request.
//
// # Where this must sit in the chain
//
// Register it at engine level, after Logger and *before* gin.Recovery(), the
// same position Logger already occupies and for the same reason: sitting outside
// Recovery means a panicking handler is still recorded, as the 500 that Recovery
// writes. Being at engine level rather than inside the JWT-gated group also
// means a request rejected by Auth is recorded as the 401 it is, instead of
// vanishing — Auth aborts without calling the next handler, so a middleware
// registered after it never runs.
//
// Sitting outside Auth costs nothing in identity. Auth publishes UserInfo by
// replacing c.Request with one carrying an enriched context, and c.Request is
// read back here *after* c.Next() returns, by which time that replacement has
// happened. So this middleware runs before Auth and still sees the attendee Auth
// resolved.
//
// # What it costs a request
//
// For a skipped route (the 5-second pollers), one map lookup before c.Next() and
// nothing after. For a recorded route, a handful of header reads and a
// non-blocking channel send. No response buffering, no I/O, no lock. A
// Recorder's Record must never block, and the two in internal/analytics do not.
func Analytics(recorder analytics.Recorder, policy analytics.RoutePolicy) gin.HandlerFunc {
	return func(c *gin.Context) {
		// FullPath is already populated by the time the handler chain runs, so
		// the skip decision is made before doing any work — which is what keeps
		// the polled endpoints genuinely free rather than merely unrecorded.
		info, track := policy.Lookup(c.Request.Method, c.FullPath())
		if !track {
			c.Next()
			return
		}

		start := time.Now()
		c.Next()
		end := time.Now()

		// Read identity after c.Next(): see the note above about Auth swapping
		// c.Request. A nil UserInfo is normal and not an error — it means the
		// request never got past Auth, and the event is simply anonymous.
		var userID string
		if user := UserInfoFromContext(c.Request.Context()); user != nil {
			userID = user.UserID
		}

		recorder.Record(analytics.Event{
			Method:          c.Request.Method,
			Route:           c.FullPath(),
			URI:             sanitizedURI(c.Request.URL),
			Feature:         info.Feature,
			Status:          c.Writer.Status(),
			Start:           start,
			End:             end,
			RequestHeaders:  pickHeaders(c.Request.Header, safeRequestHeaders),
			ResponseHeaders: pickHeaders(c.Writer.Header(), safeResponseHeaders),
			RequestBytes:    contentLength(c.Request.ContentLength),
			ResponseBytes:   contentLength(int64(c.Writer.Size())),
			IPAddress:       c.ClientIP(),
			UserID:          userID,
			Class:           string(info.Class),
		})
	}
}

// pickHeaders copies the allow-listed headers out of h. The result is a fresh
// map because the recorder marshals it on another goroutine, long after this
// request's http.Header has been recycled by the server.
func pickHeaders(h http.Header, allowed []string) map[string]string {
	out := make(map[string]string, len(allowed))
	for _, name := range allowed {
		if v := h.Get(name); v != "" {
			out[name] = v
		}
	}
	return out
}

// sanitizedURI renders the request path plus a query string whose sensitive
// values have been redacted. Parameter order is not preserved — url.Values
// re-encodes sorted by key — which is fine, because nothing downstream reads
// the query positionally and a stable ordering actually reads better in the
// Moesif UI.
func sanitizedURI(u *url.URL) string {
	if u == nil {
		return ""
	}
	if u.RawQuery == "" {
		return u.Path
	}

	// A query string that will not parse is dropped rather than guessed at:
	// passing malformed input through unexamined is how an unredacted value
	// would slip out.
	values, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return u.Path + "?" + redactedValue
	}

	for key, vals := range values {
		if _, ok := safeQueryParams[key]; ok {
			continue
		}
		for i := range vals {
			vals[i] = redactedValue
		}
	}

	return u.Path + "?" + values.Encode()
}

// contentLength normalises the two "unknown" spellings Go uses. http.Request
// reports -1 for an unknown body length and gin's ResponseWriter reports -1
// before anything is written; the recorder wants a single "nothing to say"
// value, and treats zero as exactly that.
func contentLength(n int64) int64 {
	if n < 0 {
		return 0
	}
	return n
}
