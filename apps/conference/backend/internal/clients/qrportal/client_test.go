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

package qrportal

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"wso2-coin-backend/internal/models"
)

func TestGetQRCode_Success(t *testing.T) {
	const qrID = "9a1f0f0a-1111-2222-3333-abcdefabcdef"

	want := models.ConferenceQrCode{
		QrID: qrID,
		Info: models.QrCodeInfo{
			EventType: models.EventTypeSession,
			SessionID: "session-123",
		},
		Description: "Keynote session",
		Coins:       10,
		CreatedBy:   "admin@wso2.com",
		CreatedOn:   "2026-07-15T09:00:00Z",
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("expected GET, got %s", r.Method)
		}
		expectedPath := "/qr-codes/" + qrID
		if r.URL.Path != expectedPath {
			t.Errorf("expected path %q, got %q", expectedPath, r.URL.Path)
		}
		if accept := r.Header.Get("Accept"); accept != "application/json" {
			t.Errorf("expected Accept header application/json, got %q", accept)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetQRCode(context.Background(), qrID)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil {
		t.Fatal("expected non-nil result")
	}
	if got.QrID != want.QrID {
		t.Errorf("QrID = %q, want %q", got.QrID, want.QrID)
	}
	if got.Info.EventType != models.EventTypeSession {
		t.Errorf("Info.EventType = %q, want %q", got.Info.EventType, models.EventTypeSession)
	}
	if got.Info.SessionID != "session-123" {
		t.Errorf("Info.SessionID = %q, want %q", got.Info.SessionID, "session-123")
	}
	if got.Coins != want.Coins {
		t.Errorf("Coins = %v, want %v", got.Coins, want.Coins)
	}
	if got.CreatedBy != want.CreatedBy {
		t.Errorf("CreatedBy = %q, want %q", got.CreatedBy, want.CreatedBy)
	}
}

func TestGetQRCode_NotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"qr code not found"}`))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetQRCode(context.Background(), "missing-id")
	if err == nil {
		t.Fatal("expected error for 404 response, got nil")
	}
	if got != nil {
		t.Errorf("expected nil result on error, got %+v", got)
	}
}

func TestGetQRCode_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("internal server error"))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetQRCode(context.Background(), "some-id")
	if err == nil {
		t.Fatal("expected error for 500 response, got nil")
	}
	if got != nil {
		t.Errorf("expected nil result on error, got %+v", got)
	}
}
