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

package notification

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Recipient uuids used across these tests. They have to be real, hyphenated
// UUIDs now: anything else is dropped before the request is built, because the
// notification service would otherwise read it as a group name.
const (
	recipientA = "0f2b8c1e-4a6d-4f7b-9c3a-1d5e6f708192"
	recipientB = "7a1c3d5e-2b4f-4c6a-8d9e-0f1a2b3c4d5e"
	recipientC = "c4e5f607-8a9b-4c0d-9e1f-2a3b4c5d6e7f"
)

func TestSendAttendeeNotification_PostsExpectedPayload(t *testing.T) {
	var gotPath string
	var got eventRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("Content-Type = %q, want application/json", ct)
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decoding request body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"event_id":"evt-1","message":"queued"}`))
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	err := c.SendAttendeeNotification(context.Background(), "admin-1",
		[]string{recipientA, recipientB}, "Keynote", "Starting soon")
	if err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}

	if gotPath != "/event" {
		t.Errorf("path = %q, want %q", gotPath, "/event")
	}
	if len(got.Actor.Users) != 1 || got.Actor.Users[0] != "admin-1" {
		t.Errorf("actor.users = %v, want [admin-1]", got.Actor.Users)
	}
	if len(got.Target.Users) != 2 {
		t.Errorf("target.users = %v, want 2 entries", got.Target.Users)
	}
	if got.Context.Title != "Keynote" || got.Context.Body != "Starting soon" {
		t.Errorf("context = %+v, want title/body Keynote/Starting soon", got.Context)
	}
	if got.EventType != eventType {
		t.Errorf("eventType = %q, want %q", got.EventType, eventType)
	}
	if got.Source != source {
		t.Errorf("source = %q, want %q", got.Source, source)
	}
}

// A broadcast with no addressable recipients has nothing to deliver, so the
// client must not spend a request on it.
func TestSendAttendeeNotification_NoRecipientsSkipsRequest(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	if err := c.SendAttendeeNotification(context.Background(), "admin-1", nil, "t", "b"); err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}
	if called {
		t.Error("client sent a request for an empty recipient list")
	}
}

func TestSendAttendeeNotification_NonSuccessStatusIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("upstream exploded"))
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	err := c.SendAttendeeNotification(context.Background(), "admin-1", []string{recipientA}, "t", "b")
	if err == nil {
		t.Fatal("expected an error for a 502 response, got nil")
	}
	if !strings.Contains(err.Error(), "502") {
		t.Errorf("error %q does not mention the status code", err)
	}
}

// The service's response body is intentionally discarded; a body that isn't
// even JSON must not turn a successful delivery into a failure.
func TestSendAttendeeNotification_IgnoresResponseBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte("not json at all"))
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	if err := c.SendAttendeeNotification(context.Background(), "admin-1", []string{recipientA}, "t", "b"); err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}
}

// A recipient that is neither an email nor a UUID is classified downstream as
// a GROUP NAME and delivered to that entire group
// (push-notification-service/internal/services/event/service.go). Since
// attendees.idp_uuid is a text column, one malformed row would otherwise widen
// a targeted broadcast without anyone noticing, so the client drops every
// non-UUID recipient and sends the rest.
func TestSendAttendeeNotification_DropsNonUUIDRecipients(t *testing.T) {
	var got eventRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decoding request body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	err := c.SendAttendeeNotification(context.Background(), "admin-1", []string{
		recipientA,
		"all-attendees",       // would fan out to a whole group
		"someone@example.com", // delivered by email, not to this attendee
		recipientB,
		"0f2b8c1e4a6d4f7b9c3a1d5e6f708192",   // unhyphenated: not the textual UUID form
		"0f2b8c1e-4a6d-4f7b-9c3a-1d5e6f7081", // too short
		"",                                   // an empty idp_uuid string
		recipientC,
	}, "Keynote", "Starting soon")
	if err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}

	want := []string{recipientA, recipientB, recipientC}
	if len(got.Target.Users) != len(want) {
		t.Fatalf("target.users = %v, want %v", got.Target.Users, want)
	}
	for i, u := range want {
		if got.Target.Users[i] != u {
			t.Errorf("target.users[%d] = %q, want %q", i, got.Target.Users[i], u)
		}
	}
}

// Filtering must never be able to turn a broadcast that would have reached
// nobody into one that reaches everybody: if nothing survives the filter, the
// client behaves exactly as it does for an empty list and sends no request.
func TestSendAttendeeNotification_AllRecipientsInvalidSkipsRequest(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	err := c.SendAttendeeNotification(context.Background(), "admin-1",
		[]string{"all-attendees", "speakers", "", "not-a-uuid"}, "t", "b")
	if err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}
	if called {
		t.Error("client sent a request whose every recipient was an unfiltered group name")
	}
}

// A list that is already all UUIDs must reach the service untouched: same
// values, same order, nothing added or dropped.
func TestSendAttendeeNotification_ValidUUIDsPassThroughUnchanged(t *testing.T) {
	var got eventRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decoding request body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	in := []string{recipientC, recipientA, recipientB}
	c := NewClientWithHTTPClient(srv.URL, srv.Client())
	if err := c.SendAttendeeNotification(context.Background(), "admin-1", in, "t", "b"); err != nil {
		t.Fatalf("SendAttendeeNotification returned %v, want nil", err)
	}

	if len(got.Target.Users) != len(in) {
		t.Fatalf("target.users = %v, want %v", got.Target.Users, in)
	}
	for i, u := range in {
		if got.Target.Users[i] != u {
			t.Errorf("target.users[%d] = %q, want %q", i, got.Target.Users[i], u)
		}
	}
}
