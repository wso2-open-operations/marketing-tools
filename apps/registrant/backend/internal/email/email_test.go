// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package email

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSend_Success(t *testing.T) {
	var gotPath string
	var gotPayload Payload
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotPayload)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	c := newClient(server.URL, "noreply@example.com", server.Client())
	err := c.Send(context.Background(), Payload{
		To:       []string{"attendee@example.com"},
		From:     "noreply@example.com",
		Subject:  "Your Digital Pass",
		Template: "base64content",
	})
	if err != nil {
		t.Fatalf("Send failed: %v", err)
	}
	if gotPath != "/send-email" {
		t.Errorf("path = %q, want /send-email", gotPath)
	}
	if gotPayload.Subject != "Your Digital Pass" {
		t.Errorf("subject = %q, want Your Digital Pass", gotPayload.Subject)
	}
}

func TestSend_NonOKStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"bad request"}`))
	}))
	defer server.Close()

	c := newClient(server.URL, "noreply@example.com", server.Client())
	err := c.Send(context.Background(), Payload{To: []string{"attendee@example.com"}})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSend_ClientError(t *testing.T) {
	c := newClient("http://127.0.0.1:0", "noreply@example.com", http.DefaultClient)
	err := c.Send(context.Background(), Payload{To: []string{"attendee@example.com"}})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestNewClient_TrimsTrailingSlash(t *testing.T) {
	c := NewClient(ServiceConfig{Endpoint: "https://email.example.com/", From: "noreply@example.com"})
	if c.endpoint != "https://email.example.com" {
		t.Errorf("endpoint = %q, want trimmed trailing slash", c.endpoint)
	}
}
