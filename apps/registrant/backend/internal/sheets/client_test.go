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

package sheets

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/api/option"
	sheetsapi "google.golang.org/api/sheets/v4"
)

// newTestClient spins up a fake Sheets API server driven by handler and
// returns a Client wired to it, so the request-building logic in sheet.go
// can be exercised without real Google credentials.
func newTestClient(t *testing.T, cfg Config, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	svc, err := sheetsapi.NewService(context.Background(),
		option.WithEndpoint(server.URL),
		option.WithHTTPClient(server.Client()),
		option.WithoutAuthentication(),
	)
	if err != nil {
		t.Fatalf("sheetsapi.NewService failed: %v", err)
	}
	return newClient(svc, cfg)
}

func testConfig() Config {
	return Config{
		SpreadsheetID: "sheet-id",
		SheetID:       1,
		SheetName:     "Summary",
	}
}

func TestSyncAttendeeSummary(t *testing.T) {
	var sawClear, sawAppend, sawBatchUpdate bool
	c := newTestClient(t, testConfig(), func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, ":clear"):
			sawClear = true
			_ = json.NewEncoder(w).Encode(map[string]any{"clearedRange": "Summary"})
		case strings.HasSuffix(r.URL.Path, ":append"):
			sawAppend = true
			_ = json.NewEncoder(w).Encode(map[string]any{"updates": map[string]any{"updatedRows": 3}})
		case strings.HasSuffix(r.URL.Path, ":batchUpdate"):
			sawBatchUpdate = true
			_ = json.NewEncoder(w).Encode(map[string]any{"spreadsheetId": "sheet-id", "replies": []map[string]any{{}}})
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
	})

	summaries := []AttendeeSummary{{Agenda: "Day 1", Username: "a@wso2.com", UserType: "Internal"}}
	if err := c.SyncAttendeeSummary(context.Background(), summaries, 0); err != nil {
		t.Fatalf("SyncAttendeeSummary failed: %v", err)
	}
	if !sawClear || !sawAppend || !sawBatchUpdate {
		t.Errorf("expected clear, append, and batchUpdate calls; got clear=%v append=%v batchUpdate=%v",
			sawClear, sawAppend, sawBatchUpdate)
	}
}

func TestSyncAttendeeSummary_ClearFails(t *testing.T) {
	c := newTestClient(t, testConfig(), func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})

	err := c.SyncAttendeeSummary(context.Background(), nil, 0)
	if err == nil {
		t.Fatal("expected error when clear fails")
	}
}
