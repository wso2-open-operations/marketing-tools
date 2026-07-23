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
	"time"
)

func TestAppConfig_JSONTags(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	cfg := AppConfig{
		Key:       "ATTENDEES_SYNC",
		Value:     "COMPLETED",
		CreatedBy: "SYSTEM",
		CreatedOn: now,
		UpdatedBy: "SYSTEM",
		UpdatedOn: now,
	}

	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	wantKeys := []string{"key", "value", "createdBy", "createdOn", "updatedBy", "updatedOn"}
	for _, k := range wantKeys {
		if _, ok := got[k]; !ok {
			t.Errorf("marshaled JSON missing key %q, got %v", k, got)
		}
	}
	if got["key"] != "ATTENDEES_SYNC" {
		t.Errorf("key = %v, want ATTENDEES_SYNC", got["key"])
	}
	if got["value"] != "COMPLETED" {
		t.Errorf("value = %v, want COMPLETED", got["value"])
	}
}
