// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

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
		SpreadsheetID:         "sheet-id",
		SheetID:               1,
		SheetName:             "Summary",
		RegistrationSheetName: "Registrations",
		RegistrationSheetID:   2,
	}
}

func TestGetSheetData(t *testing.T) {
	c := newTestClient(t, testConfig(), func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && !strings.Contains(r.URL.Path, "/values/"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"sheets": []map[string]any{
					{"properties": map[string]any{"gridProperties": map[string]any{"rowCount": 10}}},
				},
			})
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/values/"):
			if !strings.Contains(r.URL.Path, "Registrations") {
				t.Errorf("expected registration sheet in range, got path %q", r.URL.Path)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"values": [][]any{
					{"a@wso2.com", "uuid-1", "qr1", "wallet1", "true"},
					{"b@example.com", "uuid-2", "qr2", "wallet2", "false"},
				},
			})
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
	})

	got, err := c.GetSheetData(context.Background())
	if err != nil {
		t.Fatalf("GetSheetData failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 attendees, got %d", len(got))
	}
	if got[0].Email != "a@wso2.com" || !got[0].IsInviteSent {
		t.Errorf("attendee 0 = %+v", got[0])
	}
}

func TestGetSheetData_NoSheets(t *testing.T) {
	c := newTestClient(t, testConfig(), func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"sheets": []map[string]any{}})
	})

	_, err := c.GetSheetData(context.Background())
	if err == nil {
		t.Fatal("expected error for spreadsheet with no sheets")
	}
}

func TestUpdateAttendeeData(t *testing.T) {
	var gotPath, gotBody string
	c := newTestClient(t, testConfig(), func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path + "?" + r.URL.RawQuery
		body := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		b, _ := json.Marshal(body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"updatedRows": 1})
	})

	err := c.UpdateAttendeeData(context.Background(), 3, Attendee{
		Email: "a@wso2.com", UUID: "uuid-1", QRImageURL: "qr", WalletPassURL: "wallet", IsInviteSent: true,
	})
	if err != nil {
		t.Fatalf("UpdateAttendeeData failed: %v", err)
	}
	if !strings.Contains(gotPath, "Registrations") || !strings.Contains(gotPath, "A3%3AE3") && !strings.Contains(gotPath, "A3:E3") {
		t.Errorf("unexpected request path: %q", gotPath)
	}
	if !strings.Contains(gotBody, "a@wso2.com") || !strings.Contains(gotBody, "true") {
		t.Errorf("unexpected request body: %q", gotBody)
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
