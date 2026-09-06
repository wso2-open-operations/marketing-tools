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
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestMoesif_WirePayload drives the real SDK against a stub collector.
//
// Every other test in this package stops at the SDK's door, which leaves the one
// thing that actually decides whether data appears on a Moesif dashboard
// untested: the bytes on the wire. This test asserts the request path, the
// authentication header, the gzip encoding and the JSON field names Moesif
// requires, so a wrong guess about the collector's contract fails here rather
// than as an empty dashboard nobody can explain.
//
// It uses New rather than newWithAPI, so it also covers the SDK wiring in New
// itself. The SDK keeps its configuration in a package-level global and owns a
// flush goroutine, which is why this is one test and not a table.
func TestMoesif_WirePayload(t *testing.T) {
	type capture struct {
		path        string
		appID       string
		encoding    string
		contentType string
		body        []byte
	}

	captured := make(chan capture, 4)

	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("reading collector request: %v", err)
		}
		captured <- capture{
			path:        r.URL.Path,
			appID:       r.Header.Get("X-Moesif-Application-Id"),
			encoding:    r.Header.Get("Content-Encoding"),
			contentType: r.Header.Get("Content-Type"),
			body:        body,
		}
		// Moesif answers 201 with an empty body.
		w.WriteHeader(http.StatusCreated)
	}))
	defer collector.Close()

	cfg := testConfig()
	cfg.APIEndpoint = collector.URL

	rec, err := New(cfg, discardLogger())
	if err != nil {
		t.Fatalf("New() = %v", err)
	}

	start := time.Date(2026, 8, 20, 9, 15, 0, 0, time.UTC)
	rec.Record(Event{
		Method:          "POST",
		Route:           "/feedback",
		URI:             "/feedback",
		Feature:         FeatureFeedback,
		Class:           string(ClassIntent),
		Status:          201,
		Start:           start,
		End:             start.Add(42 * time.Millisecond),
		RequestHeaders:  map[string]string{"Content-Type": "application/json"},
		ResponseHeaders: map[string]string{"Content-Type": "application/json"},
		IPAddress:       "203.0.113.7",
		UserID:          "user-uuid-123",
	})

	// Close flushes rather than waiting out the SDK's timer.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := rec.Close(ctx); err != nil {
		t.Fatalf("Close() = %v", err)
	}

	var got capture
	select {
	case got = <-captured:
	case <-time.After(10 * time.Second):
		t.Fatal("collector received nothing")
	}

	if got.path != "/v1/events/batch" {
		t.Errorf("path = %q, want /v1/events/batch", got.path)
	}
	if got.appID != cfg.ApplicationID {
		t.Errorf("X-Moesif-Application-Id = %q, want %q", got.appID, cfg.ApplicationID)
	}
	if got.encoding != "gzip" {
		t.Errorf("Content-Encoding = %q, want gzip", got.encoding)
	}
	if got.contentType != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want application/json; charset=utf-8", got.contentType)
	}

	gz, err := gzip.NewReader(bytes.NewReader(got.body))
	if err != nil {
		t.Fatalf("body is not gzip: %v", err)
	}
	plain, err := io.ReadAll(gz)
	if err != nil {
		t.Fatalf("inflating body: %v", err)
	}

	// A batch is a JSON array, even for one event.
	var events []map[string]any
	if err := json.Unmarshal(plain, &events); err != nil {
		t.Fatalf("body is not a JSON array of events: %v\n%s", err, plain)
	}
	if len(events) != 1 {
		t.Fatalf("batch carried %d events, want 1", len(events))
	}
	event := events[0]

	if got := event["user_id"]; got != "user-uuid-123" {
		t.Errorf("user_id = %v, want user-uuid-123", got)
	}
	if got := event["direction"]; got != "Incoming" {
		t.Errorf("direction = %v, want Incoming", got)
	}

	request, ok := event["request"].(map[string]any)
	if !ok {
		t.Fatalf("request is %T, want an object", event["request"])
	}
	if got := request["verb"]; got != "POST" {
		t.Errorf("request.verb = %v, want POST", got)
	}
	if got := request["uri"]; got != "/feedback" {
		t.Errorf("request.uri = %v, want /feedback", got)
	}
	if got := request["ip_address"]; got != "203.0.113.7" {
		t.Errorf("request.ip_address = %v, want 203.0.113.7", got)
	}
	if _, present := request["body"]; present {
		t.Error("request carries a body; this integration must never send bodies")
	}

	response, ok := event["response"].(map[string]any)
	if !ok {
		t.Fatalf("response is %T, want an object", event["response"])
	}
	if got := response["status"]; got != float64(201) {
		t.Errorf("response.status = %v, want 201", got)
	}

	// The response object does carry a body key, and it is always null. Unlike
	// the request model's, the SDK's response Body field has no omitempty, so
	// the key cannot be suppressed without hand-rolling the wire type. Null
	// says "not captured" to Moesif just as an absent key does, so this is
	// pinned rather than fixed -- but it must stay null, which is the part
	// worth asserting.
	body, present := response["body"]
	if !present {
		t.Error("response.body key vanished; the SDK's wire model changed, re-check this assumption")
	}
	if body != nil {
		t.Errorf("response.body = %v, want null; this integration must never send bodies", body)
	}

	// Moesif derives latency from these two timestamps, so they have to be
	// parseable RFC 3339 and they have to differ.
	requestTime, err := time.Parse(time.RFC3339Nano, request["time"].(string))
	if err != nil {
		t.Fatalf("request.time is not RFC 3339: %v", err)
	}
	responseTime, err := time.Parse(time.RFC3339Nano, response["time"].(string))
	if err != nil {
		t.Fatalf("response.time is not RFC 3339: %v", err)
	}
	if latency := responseTime.Sub(requestTime); latency != 42*time.Millisecond {
		t.Errorf("latency on the wire = %v, want 42ms", latency)
	}

	metadata, ok := event["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("metadata is %T, want an object", event["metadata"])
	}
	for key, want := range map[string]string{
		"projectName": cfg.ProjectName,
		"appName":     cfg.AppName,
		"env":         cfg.Environment,
		"route":       "/feedback",
		"feature":     FeatureFeedback,
		"class":       string(ClassIntent),
	} {
		if metadata[key] != want {
			t.Errorf("metadata[%q] = %v, want %q", key, metadata[key], want)
		}
	}
}
