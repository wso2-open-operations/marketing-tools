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

package wallet

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"wso2-coin-backend/internal/models"
)

func TestGetPrimaryWallet_Success(t *testing.T) {
	const email = "user+test@wso2.com"
	want := models.Wallet{WalletAddress: "0xABCDEF1234567890"}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("expected GET, got %s", r.Method)
		}
		if r.URL.Path != "/wallets/primary" {
			t.Errorf("expected path /wallets/primary, got %q", r.URL.Path)
		}
		if got := r.URL.Query().Get("email"); got != email {
			t.Errorf("expected email query param %q, got %q", email, got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(want)
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetPrimaryWallet(context.Background(), email)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil {
		t.Fatal("expected non-nil wallet")
	}
	if got.WalletAddress != want.WalletAddress {
		t.Errorf("WalletAddress = %q, want %q", got.WalletAddress, want.WalletAddress)
	}
}

func TestGetPrimaryWallet_NotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"no wallet"}`))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetPrimaryWallet(context.Background(), "nobody@wso2.com")
	if err != nil {
		t.Fatalf("expected no error for 404 (no wallet), got %v", err)
	}
	if got != nil {
		t.Errorf("expected nil wallet for 404, got %+v", got)
	}
}

func TestGetPrimaryWallet_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("internal server error"))
	}))
	defer server.Close()

	client := NewClientWithHTTPClient(server.URL, server.Client())

	got, err := client.GetPrimaryWallet(context.Background(), "user@wso2.com")
	if err == nil {
		t.Fatal("expected error for 500 response, got nil")
	}
	if got != nil {
		t.Errorf("expected nil wallet on error, got %+v", got)
	}
}
