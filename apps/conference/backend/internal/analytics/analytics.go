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

// Package analytics ships one API-usage event per served request to Moesif so
// that product questions ("is anyone using the AI agenda?", "did the shop get
// opened after day one?", "which screens do attendees never reach?") can be
// answered from the API tier instead of from a client-side analytics SDK the
// microapp does not have.
//
// This is a deliberate re-think of the Ballerina integration in the private
// digiops-marketing repo (conference_app/modules/analytics), not a port of it.
// That version called Moesif synchronously from inside nine handler bodies,
// with a 300-second client timeout, hand-written status codes, request.time and
// response.time sampled one line apart (so every event reported ~0 ms latency),
// no user identity, and no way to switch it off. Everything below exists to
// avoid repeating one of those:
//
//   - Events are recorded by a Gin middleware, from the real response status
//     and the real wall-clock span, so latency and error rates on the Moesif
//     dashboard mean something.
//   - Recording is non-blocking. Record never does I/O on the request
//     goroutine; it hands the event to the Moesif SDK's queue, which batches
//     and flushes on its own timer. A full queue drops the event.
//   - A dead or slow Moesif can never fail, slow, or panic a request. There is
//     no code path from a Moesif error back to the caller.
//   - MOESIF_ENABLED gates the whole thing, and a disabled build uses Nop,
//     which compiles down to an empty method call.
//
// # What is deliberately not sent
//
// No request or response bodies, ever. This API's payloads are attendee PII:
// names, emails, titles, companies, LinkedIn URLs (encrypted at rest by
// internal/crypto precisely because they are sensitive), plus free-text AI chat
// prompts. None of that belongs in a third-party analytics product, and none of
// it is needed to answer a feature-usage question. Not capturing bodies also
// means the middleware never has to buffer a response, so instrumenting an
// endpoint costs no extra allocation per byte served.
//
// Request and response headers are allowlisted, not filtered — see
// safeRequestHeaders. Authorization and x-jwt-assertion carry bearer tokens for
// a live session and are not on the list.
//
// user_id is the attendee's UUID, never their email address. It is enough to
// count distinct users, build funnels, and follow one attendee's session, and
// it is meaningless outside this database.
package analytics

import (
	"context"
	"time"
)

// Event is one served HTTP request, in the shape this package needs to describe
// it. It is intentionally decoupled from both gin.Context and the Moesif SDK's
// models: the middleware fills this in and is done, and the mapping onto
// Moesif's wire format lives in exactly one place (moesif.go).
type Event struct {
	// Method is the real HTTP verb, e.g. "GET".
	Method string

	// Route is the Gin route template that matched, e.g. "/sessions/:id".
	// This is the field to group by in Moesif when asking "how often is this
	// endpoint called": URI carries the substituted ids and would scatter one
	// endpoint across thousands of distinct values.
	Route string

	// URI is the request path with its query string, e.g.
	// "/attendees?cursor=abc&limit=20". Moesif requires it and it is what the
	// dashboard shows per event.
	URI string

	// Feature is the product area Route belongs to ("agenda", "shop",
	// "ai-agent", ...), so a dashboard can answer "is this feature used" in one
	// group-by instead of by remembering which routes belong together.
	Feature string

	// Class says what a call to Route means — a deliberate action, a screen
	// mounting, or a timer ticking. See the Class constants in routes.go. It is
	// carried as a string rather than as Class so that Event stays a plain
	// description of a request that anything could fill in.
	Class string

	// Status is the response status actually written, not an assumed one.
	Status int

	// Start and End bracket the handler chain, so End.Sub(Start) is the latency
	// Moesif reports.
	Start time.Time
	End   time.Time

	// RequestHeaders and ResponseHeaders are already allowlisted by the caller.
	RequestHeaders  map[string]string
	ResponseHeaders map[string]string

	// RequestBytes and ResponseBytes are the declared/observed content lengths.
	// Zero means "not known", which is normal for a request with no body.
	RequestBytes  int64
	ResponseBytes int64

	// IPAddress is the client IP as resolved through the proxy chain. Moesif
	// uses it for the geography and device breakdowns.
	IPAddress string

	// UserID identifies the attendee. Empty for unauthenticated routes, which
	// Moesif is happy to accept — those events simply have no user attached.
	UserID string
}

// Duration is the wall-clock time the request took. Zero if the event was
// never completed.
func (e Event) Duration() time.Duration {
	if e.Start.IsZero() || e.End.IsZero() {
		return 0
	}
	return e.End.Sub(e.Start)
}

// Recorder accepts usage events. Implementations must be safe for concurrent
// use and must not block: Record runs on the request goroutine, after the
// response has been written but before the handler chain unwinds.
type Recorder interface {
	// Record enqueues one event. It never returns an error, because there is
	// nothing a request handler could usefully do about a failure to record
	// analytics, and every plausible reaction (retry, log, fail the request) is
	// worse than dropping the event.
	Record(Event)

	// Close flushes whatever is still queued and releases the recorder. It
	// respects ctx so a slow Moesif cannot hold up process shutdown past the
	// server's own drain deadline.
	Close(ctx context.Context) error
}

// Nop is the Recorder used when MOESIF_ENABLED is false. It exists so that
// neither the middleware nor its callers need a nil check: wiring is identical
// whether or not analytics is switched on.
type Nop struct{}

// Record discards the event.
func (Nop) Record(Event) {}

// Close is a no-op.
func (Nop) Close(context.Context) error { return nil }

// Assert at compile time that both recorders satisfy the interface.
var (
	_ Recorder = Nop{}
	_ Recorder = (*Moesif)(nil)
)
