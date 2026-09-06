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
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	moesifapi "github.com/moesif/moesifapi-go"
	"github.com/moesif/moesifapi-go/models"
)

const (
	// defaultAPIEndpoint is Moesif's global collector. The EU collector and a
	// local stub are the only reasons to override it, which is why it is the
	// one of these four that is configurable.
	defaultAPIEndpoint = "https://api.moesif.net"

	// queueSize bounds how many events may wait in memory for the sender. It
	// is sized for a conference, not for a public API: at the microapp's
	// tracked request rates this is minutes of peak keynote traffic, and
	// holding more than that while Moesif is unreachable would be hoarding
	// data nobody will read rather than protecting a signal. Past this point
	// events are dropped and counted — see noteDrop.
	queueSize = 10000

	// batchSize is how many events go in one POST to /v1/events/batch. Moesif
	// documents a 250 KB body limit; without bodies an event is a few hundred
	// bytes, so 200 stays comfortably inside it.
	batchSize = 200

	// flushInterval is how long an event may sit in the buffer before being
	// sent. Two seconds keeps the dashboard feeling live during a demo without
	// making a POST per request.
	flushInterval = 2 * time.Second
)

// Config is the deployment-facing configuration for the Moesif recorder. It is
// deliberately a plain struct owned by this package rather than a reference to
// internal/config: main destructures the process config and hands each
// collaborator only what it needs, the same way middleware.AuthConfig and
// service.ShopConfig work.
type Config struct {
	// ApplicationID is the Moesif Collector Application Id, sent as the
	// X-Moesif-Application-Id header. Required.
	ApplicationID string

	// APIEndpoint overrides the Moesif collector base URL. Empty means
	// https://api.moesif.net. Exists for the Moesif EU collector and for
	// pointing a test at a local stub, not for everyday configuration.
	APIEndpoint string

	// ProjectName and AppName land in every event's metadata. They keep the
	// naming the Ballerina service already writes into the same Moesif
	// workspace ("marketing-web" / "con-app-backend"), so events from the two
	// services can be told apart and compared rather than silently merged.
	ProjectName string
	AppName     string

	// Environment separates production traffic from a developer's laptop in the
	// dashboard. Fed from APP_ENV.
	Environment string
}

// ErrNoApplicationID is returned by New when analytics is switched on without a
// Collector Application Id. This is a hard startup error rather than a silent
// downgrade to Nop on purpose: "analytics is enabled but every event is being
// thrown away" is indistinguishable, from the outside, from "nobody used the
// app today", and that is the one wrong answer this package exists to avoid.
var ErrNoApplicationID = errors.New("analytics: MOESIF_APPLICATION_ID is required when MOESIF_ENABLED=true")

// Moesif is a Recorder that batches events to the Moesif collector through the
// official SDK. The SDK owns the queue, the batching timer, gzip, and the HTTP
// call; this type owns the mapping from Event onto Moesif's wire model and the
// promise that none of that can affect a request.
type Moesif struct {
	api    moesifapi.API
	logger *slog.Logger

	// metadata is the static part of every event's metadata, built once. The
	// per-event fields are copied onto a fresh map in eventModel, because the
	// SDK marshals asynchronously and must never share a map with a live
	// request goroutine.
	metadata map[string]string

	// direction is Moesif's incoming/outgoing discriminator, hoisted to a field
	// because the wire model wants a *string.
	direction string

	// dropped counts events discarded because the SDK queue was full. It is a
	// counter rather than a log line per drop: the moment this starts firing it
	// fires thousands of times, and drowning the request log is a worse outcome
	// than losing analytics.
	dropped atomic.Uint64
}

// New builds a Moesif recorder. It returns ErrNoApplicationID if cfg has no
// Application Id; every other field falls back to a documented default.
//
// Note that the Moesif SDK keeps its configuration in a package-level global
// and starts its flush goroutine inside NewAPI, so exactly one recorder may
// exist per process. That matches how it is wired (once, in main), but it is
// why this is not something to construct per request or per test table row.
func New(cfg Config, logger *slog.Logger) (*Moesif, error) {
	if cfg.ApplicationID == "" {
		return nil, ErrNoApplicationID
	}
	if logger == nil {
		logger = slog.Default()
	}

	endpoint := cfg.APIEndpoint
	if endpoint == "" {
		endpoint = defaultAPIEndpoint
	}

	api := moesifapi.NewAPI(cfg.ApplicationID, &endpoint, queueSize, batchSize, int(flushInterval.Seconds()))

	return newWithAPI(api, cfg, logger), nil
}

// newWithAPI is the seam the tests use: it takes an already-built API so a fake
// can stand in for the real collector without touching the SDK's global config
// or spawning its flush goroutine.
func newWithAPI(api moesifapi.API, cfg Config, logger *slog.Logger) *Moesif {
	metadata := map[string]string{}
	if cfg.ProjectName != "" {
		metadata["projectName"] = cfg.ProjectName
	}
	if cfg.AppName != "" {
		metadata["appName"] = cfg.AppName
	}
	if cfg.Environment != "" {
		metadata["env"] = cfg.Environment
	}

	return &Moesif{
		api:       api,
		logger:    logger,
		metadata:  metadata,
		direction: "Incoming",
	}
}

// Record maps e onto Moesif's event model and hands it to the SDK's queue.
//
// The only blocking work here is building a small struct and a non-blocking
// channel send. QueueEvent returns an error instead of blocking when the queue
// is full, which is the behaviour this package wants: shedding an analytics
// event is always preferable to adding latency to an attendee's request.
func (m *Moesif) Record(e Event) {
	if err := m.api.QueueEvent(m.eventModel(e)); err != nil {
		m.noteDrop(e, err)
	}
}

// noteDrop accounts for a dropped event and logs sparsely: the first drop, then
// every thousandth. A full queue means Moesif has been unreachable for a while,
// so the interesting information is "it started" and "it is still going", not
// each individual casualty.
func (m *Moesif) noteDrop(e Event, err error) {
	n := m.dropped.Add(1)
	if n != 1 && n%1000 != 0 {
		return
	}
	m.logger.Warn("dropping analytics event, moesif queue is full",
		"error", err,
		"route", e.Route,
		"dropped_total", n,
	)
}

// Dropped reports how many events have been discarded because the queue was
// full. Exposed so that a future /health detail or a test can tell "no traffic"
// apart from "traffic that never reached Moesif".
func (m *Moesif) Dropped() uint64 { return m.dropped.Load() }

// Close flushes the SDK's queue and stops its goroutine, giving up when ctx
// expires.
//
// The timeout matters: the SDK's Close is a synchronous handshake with its
// flush loop over an unbuffered channel, so if that loop is wedged mid-HTTP
// call Close never returns. Bounding it keeps a sick Moesif from holding the
// process open past the server's own drain deadline. The goroutine is left
// behind on timeout, which is fine precisely because this only ever runs on the
// way out of the process.
func (m *Moesif) Close(ctx context.Context) error {
	done := make(chan struct{})
	go func() {
		defer close(done)
		m.api.Close()
	}()

	select {
	case <-done:
		if n := m.dropped.Load(); n > 0 {
			m.logger.Warn("analytics shut down with dropped events", "dropped_total", n)
		}
		return nil
	case <-ctx.Done():
		return fmt.Errorf("analytics: moesif flush unfinished at shutdown: %w", ctx.Err())
	}
}

// eventModel maps an Event onto the Moesif wire model.
//
// Two Moesif fields are deliberately left unset, and it is worth knowing why
// before adding them:
//
//   - request.body / response.body. Not captured at all; see the package
//     comment. Moesif treats a missing body as "not recorded", not as "empty".
//     Note the asymmetry on the wire: the SDK's request model tags Body with
//     omitempty so the key disappears, while its response model does not, so
//     every event ships "body": null. Both mean the same thing to Moesif, and
//     suppressing the second would mean hand-rolling the wire type.
//   - company_id. A conference dashboard sliced by employer would be genuinely
//     useful, but the attendee's company is an encrypted column that would cost
//     a decrypt-and-join on every single request to fill in. If it is ever
//     wanted, it belongs on a periodic QueueCompany/QueueUser sync, not here.
func (m *Moesif) eventModel(e Event) *models.EventModel {
	start := e.Start.UTC()
	end := e.End.UTC()

	// Moesif derives latency from these two timestamps, so an event whose End
	// was never set would report a nonsensical span. Collapse it to the start
	// instant instead, which reads as 0 ms rather than as 56 years.
	if e.End.IsZero() {
		end = start
	}

	metadata := make(map[string]string, len(m.metadata)+3)
	for k, v := range m.metadata {
		metadata[k] = v
	}
	if e.Route != "" {
		metadata["route"] = e.Route
	}
	if e.Feature != "" {
		metadata["feature"] = e.Feature
	}
	if e.Class != "" {
		metadata["class"] = e.Class
	}

	event := &models.EventModel{
		Request: models.EventRequestModel{
			Time:          &start,
			Uri:           e.URI,
			Verb:          e.Method,
			Headers:       nonNilHeaders(e.RequestHeaders),
			IpAddress:     optionalString(e.IPAddress),
			ContentLength: optionalLength(e.RequestBytes),
		},
		Response: models.EventResponseModel{
			Time:          &end,
			Status:        e.Status,
			Headers:       nonNilHeaders(e.ResponseHeaders),
			ContentLength: optionalLength(e.ResponseBytes),
		},
		Metadata:  metadata,
		UserId:    optionalString(e.UserID),
		Direction: &m.direction,
	}

	return event
}

// nonNilHeaders guarantees a JSON object rather than null for Moesif's required
// headers field.
func nonNilHeaders(h map[string]string) map[string]string {
	if h == nil {
		return map[string]string{}
	}
	return h
}

// optionalString omits an empty value instead of sending "". An event with no
// user attached must have no user_id key at all, otherwise Moesif records an
// attendee whose id is the empty string and every anonymous call looks like one
// very busy person.
func optionalString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// optionalLength omits a zero or unknown length. Zero is ambiguous — "no body"
// and "length not observed" are both zero here — and Moesif's field is
// optional, so saying nothing is more honest than asserting 0.
func optionalLength(n int64) *int64 {
	if n <= 0 {
		return nil
	}
	return &n
}
