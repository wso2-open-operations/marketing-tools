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
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	moesifapi "github.com/moesif/moesifapi-go"
	"github.com/moesif/moesifapi-go/models"
)

// fakeAPI stands in for the Moesif SDK client. The interface is embedded rather
// than implemented: only the three methods this package calls are defined, and
// any other call would nil-panic loudly instead of passing silently, which is
// what a fake should do.
type fakeAPI struct {
	moesifapi.API

	mu       sync.Mutex
	queued   []*models.EventModel
	queueErr error
	closed   bool

	// blockClose makes Close hang, so the shutdown timeout can be exercised
	// without waiting on a real network call.
	blockClose chan struct{}
}

func (f *fakeAPI) QueueEvent(e *models.EventModel) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.queueErr != nil {
		return f.queueErr
	}
	f.queued = append(f.queued, e)
	return nil
}

func (f *fakeAPI) Close() {
	if f.blockClose != nil {
		<-f.blockClose
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
}

func (f *fakeAPI) events() []*models.EventModel {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*models.EventModel(nil), f.queued...)
}

func (f *fakeAPI) wasClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// discardLogger keeps the warn-on-drop paths from writing to test output.
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func testConfig() Config {
	return Config{
		ApplicationID: "test-app-id",
		ProjectName:   "marketing-web",
		AppName:       "conference-backend",
		Environment:   "test",
	}
}

func TestNew_WithoutApplicationID_Errors(t *testing.T) {
	rec, err := New(Config{}, discardLogger())
	if !errors.Is(err, ErrNoApplicationID) {
		t.Fatalf("err = %v, want ErrNoApplicationID", err)
	}
	if rec != nil {
		t.Error("recorder should be nil when construction fails")
	}
}

// The application id travels as a header on every batch, so a plaintext
// collector puts a credential on the wire. Loopback is the deliberate hole: a
// local stub has no network to intercept.
func TestNew_RejectsInsecureEndpoint(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		wantErr  bool
	}{
		{"empty means the global https collector", "", false},
		{"https collector", "https://api-eu.moesif.net", false},
		{"loopback stub over http", "http://127.0.0.1:8080", false},
		{"localhost stub over http", "http://localhost:8080", false},
		{"remote collector over http", "http://api.moesif.net", true},
		{"no scheme at all", "api.moesif.net", true},
		{"a scheme that is neither", "ftp://api.moesif.net", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := CheckEndpoint(tt.endpoint)
			if tt.wantErr && !errors.Is(err, ErrInsecureEndpoint) {
				t.Fatalf("CheckEndpoint(%q) = %v, want ErrInsecureEndpoint", tt.endpoint, err)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("CheckEndpoint(%q) = %v, want nil", tt.endpoint, err)
			}
		})
	}
}

func TestRecord_MapsEventOntoMoesifModel(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	start := time.Date(2026, 8, 20, 9, 15, 0, 0, time.UTC)

	rec.Record(Event{
		Method:          "POST",
		Route:           "/assistant/chat",
		URI:             "/assistant/chat",
		Feature:         FeatureAIAgent,
		Class:           string(ClassIntent),
		Status:          201,
		Start:           start,
		End:             start.Add(1500 * time.Millisecond),
		RequestHeaders:  map[string]string{"Content-Type": "application/json"},
		ResponseHeaders: map[string]string{"Content-Type": "application/json"},
		RequestBytes:    128,
		ResponseBytes:   4096,
		IPAddress:       "203.0.113.7",
		UserID:          "user-uuid-123",
	})

	events := api.events()
	if len(events) != 1 {
		t.Fatalf("queued %d events, want 1", len(events))
	}
	got := events[0]

	if got.Request.Verb != "POST" {
		t.Errorf("request.verb = %q, want POST", got.Request.Verb)
	}
	if got.Request.Uri != "/assistant/chat" {
		t.Errorf("request.uri = %q, want /assistant/chat", got.Request.Uri)
	}
	if got.Response.Status != 201 {
		t.Errorf("response.status = %d, want 201", got.Response.Status)
	}

	// Latency is the whole reason this is a middleware rather than 42 inline
	// calls: the two timestamps must be a real span, not the same instant.
	if got.Request.Time == nil || got.Response.Time == nil {
		t.Fatal("both timestamps must be set")
	}
	if latency := got.Response.Time.Sub(*got.Request.Time); latency != 1500*time.Millisecond {
		t.Errorf("latency = %v, want 1.5s", latency)
	}

	if got.UserId == nil || *got.UserId != "user-uuid-123" {
		t.Errorf("user_id = %v, want user-uuid-123", got.UserId)
	}
	if got.Request.IpAddress == nil || *got.Request.IpAddress != "203.0.113.7" {
		t.Errorf("request.ip_address = %v, want 203.0.113.7", got.Request.IpAddress)
	}
	if got.Request.ContentLength == nil || *got.Request.ContentLength != 128 {
		t.Errorf("request.content_length = %v, want 128", got.Request.ContentLength)
	}
	if got.Response.ContentLength == nil || *got.Response.ContentLength != 4096 {
		t.Errorf("response.content_length = %v, want 4096", got.Response.ContentLength)
	}
	if got.Direction == nil || *got.Direction != "Incoming" {
		t.Errorf("direction = %v, want Incoming", got.Direction)
	}

	metadata, ok := got.Metadata.(map[string]string)
	if !ok {
		t.Fatalf("metadata is %T, want map[string]string", got.Metadata)
	}
	for key, want := range map[string]string{
		"projectName": "marketing-web",
		"appName":     "conference-backend",
		"env":         "test",
		"route":       "/assistant/chat",
		"feature":     FeatureAIAgent,
		"class":       string(ClassIntent),
	} {
		if metadata[key] != want {
			t.Errorf("metadata[%q] = %q, want %q", key, metadata[key], want)
		}
	}
}

// TestRecord_NeverSendsBodies is the test that has to keep passing. The payloads
// on this API are attendee PII and free-text AI prompts; if a well-meaning
// change starts capturing bodies, it should fail here rather than on a Moesif
// dashboard six weeks later.
func TestRecord_NeverSendsBodies(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	rec.Record(Event{Method: "POST", Route: "/attendees/search", URI: "/attendees/search", Status: 200})

	got := api.events()[0]
	if got.Request.Body != nil {
		t.Errorf("request.body = %v, want nil", *got.Request.Body)
	}
	if got.Response.Body != nil {
		t.Errorf("response.body = %v, want nil", got.Response.Body)
	}

	// Serialised, too: a non-nil-but-empty container would still ship a "body"
	// key to Moesif and read as "we captured an empty body".
	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshalling event: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("decoding event: %v", err)
	}
	if _, present := decoded["request"].(map[string]any)["body"]; present {
		t.Error("serialised request carries a body key")
	}
}

func TestRecord_AnonymousEventOmitsUserID(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	rec.Record(Event{Method: "GET", Route: "/events", URI: "/events", Status: 401})

	if got := api.events()[0]; got.UserId != nil {
		// An empty-string user_id would make every unauthenticated call look
		// like one extremely busy attendee.
		t.Errorf("user_id = %q, want it omitted", *got.UserId)
	}
}

func TestRecord_HeadersAreAnObjectNotNull(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	rec.Record(Event{Method: "GET", Route: "/events", URI: "/events", Status: 200})

	got := api.events()[0]
	if h, ok := got.Request.Headers.(map[string]string); !ok || h == nil {
		t.Errorf("request.headers = %#v, want an empty map", got.Request.Headers)
	}
	if h, ok := got.Response.Headers.(map[string]string); !ok || h == nil {
		t.Errorf("response.headers = %#v, want an empty map", got.Response.Headers)
	}
}

func TestRecord_MissingEndTimeCollapsesToZeroLatency(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	start := time.Date(2026, 8, 20, 9, 15, 0, 0, time.UTC)
	rec.Record(Event{Method: "GET", Route: "/events", URI: "/events", Status: 200, Start: start})

	got := api.events()[0]
	if latency := got.Response.Time.Sub(*got.Request.Time); latency != 0 {
		t.Errorf("latency = %v, want 0 rather than an epoch-sized span", latency)
	}
}

func TestRecord_FullQueueDropsAndCounts(t *testing.T) {
	api := &fakeAPI{queueErr: errors.New("queue is full")}
	rec := newWithAPI(api, testConfig(), discardLogger())

	for range 3 {
		rec.Record(Event{Method: "GET", Route: "/events", URI: "/events", Status: 200})
	}

	if got := rec.Dropped(); got != 3 {
		t.Errorf("Dropped() = %d, want 3", got)
	}
	if len(api.events()) != 0 {
		t.Error("nothing should have been queued")
	}
}

func TestClose_FlushesTheAPI(t *testing.T) {
	api := &fakeAPI{}
	rec := newWithAPI(api, testConfig(), discardLogger())

	if err := rec.Close(context.Background()); err != nil {
		t.Fatalf("Close() = %v, want nil", err)
	}
	if !api.wasClosed() {
		t.Error("underlying API was not closed")
	}
}

// TestClose_HungFlushRespectsContext covers the reason Close takes a context at
// all: the SDK's Close is a synchronous handshake with its own goroutine, so a
// wedged sender would otherwise hold the process open forever.
func TestClose_HungFlushRespectsContext(t *testing.T) {
	block := make(chan struct{})
	defer close(block)

	api := &fakeAPI{blockClose: block}
	rec := newWithAPI(api, testConfig(), discardLogger())

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	err := rec.Close(ctx)
	if err == nil {
		t.Fatal("Close() = nil, want a deadline error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Close() = %v, want it to wrap context.DeadlineExceeded", err)
	}
}

func TestNop_IsInert(t *testing.T) {
	var rec Recorder = Nop{}
	rec.Record(Event{Method: "GET", Route: "/events"})
	if err := rec.Close(context.Background()); err != nil {
		t.Errorf("Close() = %v, want nil", err)
	}
}

func TestEvent_Duration(t *testing.T) {
	start := time.Date(2026, 8, 20, 9, 15, 0, 0, time.UTC)

	if got := (Event{Start: start, End: start.Add(time.Second)}).Duration(); got != time.Second {
		t.Errorf("Duration() = %v, want 1s", got)
	}
	if got := (Event{Start: start}).Duration(); got != 0 {
		t.Errorf("Duration() with no end = %v, want 0", got)
	}
	if got := (Event{}).Duration(); got != 0 {
		t.Errorf("Duration() of a zero event = %v, want 0", got)
	}
}
