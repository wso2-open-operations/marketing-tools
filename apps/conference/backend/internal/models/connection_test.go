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

func TestUserConnectionRequest_UnmarshalDefaultsToPending(t *testing.T) {
	var req UserConnectionRequest
	if err := json.Unmarshal([]byte(`{"userId":"u1"}`), &req); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	if req.Status != ConnectionPending {
		t.Errorf("Status = %v, want ConnectionPending (0) when omitted from payload", req.Status)
	}
}
