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

package models

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestUserConnectionsInfo_JSONShape(t *testing.T) {
	info := UserConnectionsInfo{
		RequestsSent:     []ConnectionUserInfo{{UserID: "u1", Name: "Alice", Email: "alice@example.com"}},
		RequestsReceived: []ConnectionUserInfo{},
		Connections:      []ConnectionUserInfo{},
	}

	b, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"requestsSent", "requestsReceived", "connections"} {
		arr, ok := got[key].([]any)
		if !ok {
			t.Errorf("expected JSON array key %q, got %v", key, got[key])
			continue
		}
		if key != "requestsSent" && len(arr) != 0 {
			t.Errorf("%s = %v, want empty array, not omitted", key, arr)
		}
	}
}

func TestConnectionUserInfo_OptionalFieldsOmittedWhenEmpty(t *testing.T) {
	u := ConnectionUserInfo{UserID: "u1", Name: "Alice", Email: "alice@example.com"}

	b, err := json.Marshal(u)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"profileUrl", "title", "company", "country"} {
		if _, ok := got[key]; ok {
			t.Errorf("expected %q to be omitted when empty, got %v", key, got)
		}
	}
}

func TestConnectionState_String(t *testing.T) {
	cases := map[ConnectionState]string{
		ConnectionPending:      "pending",
		ConnectionAccepted:     "accepted",
		ConnectionState("rot"): "unknown",
		ConnectionState(""):    "unknown",
	}
	for state, want := range cases {
		if got := state.String(); got != want {
			t.Errorf("ConnectionState(%q).String() = %q, want %q", string(state), got, want)
		}
	}
}

func TestConnectionState_DeclinedIsNotAState(t *testing.T) {
	// Declining deletes the row. A stored "declined" would be invisible to
	// every response yet would block the pair from ever reconnecting, so it
	// must not validate -- see migrations/014.
	if ConnectionState("declined").IsValid() {
		t.Error(`ConnectionState("declined").IsValid() = true, want false`)
	}
	if ConnectionState("rejected").IsValid() {
		t.Error(`ConnectionState("rejected").IsValid() = true, want false`)
	}
}

func TestConnectionUserInfo_StatusAndConnectionIDAlwaysPresent(t *testing.T) {
	// Both carry state the client cannot reconstruct: status names the state
	// explicitly, connectionId is the only handle on the accept/delete routes.
	// Neither may be omitempty.
	b, err := json.Marshal(ConnectionUserInfo{UserID: "u1", Name: "Alice", Email: "a@example.com"})
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	for _, key := range []string{"status", "connectionId"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected %q to always be present, got %v", key, got)
		}
	}
}

func TestConnectionRequest_TargetIDIsRequiredAndIsTheOnlyField(t *testing.T) {
	rt := reflect.TypeOf(ConnectionRequest{})

	f, ok := rt.FieldByName("TargetID")
	if !ok {
		t.Fatal("ConnectionRequest has no TargetID field")
	}
	if got := f.Tag.Get("binding"); got != "required" {
		t.Errorf("TargetID binding tag = %q, want %q", got, "required")
	}
	if got := f.Tag.Get("json"); got != "targetId" {
		t.Errorf("TargetID json tag = %q, want %q", got, "targetId")
	}

	// The redesign's core claim is that no caller-settable field decides the
	// transition. A second field on the request body would reintroduce one.
	if rt.NumField() != 1 {
		var names []string
		for i := range rt.NumField() {
			names = append(names, rt.Field(i).Name)
		}
		t.Errorf("ConnectionRequest fields = %v, want only TargetID", names)
	}
}

func TestConnection_Other(t *testing.T) {
	conn := Connection{ID: "c1", RequesterID: "alice", AddresseeID: "bob", State: ConnectionPending}

	cases := []struct {
		caller    string
		wantOther string
		wantOK    bool
	}{
		{"alice", "bob", true},
		{"bob", "alice", true},
		{"mallory", "", false},
		{"", "", false},
	}
	for _, tc := range cases {
		other, ok := conn.Other(tc.caller)
		if other != tc.wantOther || ok != tc.wantOK {
			t.Errorf("Other(%q) = (%q, %v), want (%q, %v)", tc.caller, other, ok, tc.wantOther, tc.wantOK)
		}
	}
}
