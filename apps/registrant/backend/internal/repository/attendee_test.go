// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

import (
	"context"
	"testing"

	"attendee-registration/internal/crypto"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestGetAttendeeSummary(t *testing.T) {
	repo, mock := newMockRepo(t)

	encInternal, err := crypto.Encrypt("attendee@wso2.com")
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	encExternal, err := crypto.Encrypt("external@example.com")
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}

	rows := sqlmock.NewRows([]string{"agenda", "username", "scannedBy"}).
		AddRow("Day 1", encInternal, "admin@wso2.com").
		AddRow("Day 1", encExternal, nil)
	mock.ExpectQuery("SELECT").WillReturnRows(rows)

	got, err := repo.GetAttendeeSummary(context.Background())
	if err != nil {
		t.Fatalf("GetAttendeeSummary failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(got))
	}

	if got[0].Username != "attendee@wso2.com" {
		t.Errorf("row 0 Username = %q, want attendee@wso2.com", got[0].Username)
	}
	if got[0].UserType != "Internal" {
		t.Errorf("row 0 UserType = %q, want Internal", got[0].UserType)
	}
	if got[0].ScannedBy == nil || *got[0].ScannedBy != "admin@wso2.com" {
		t.Errorf("row 0 ScannedBy = %v, want admin@wso2.com", got[0].ScannedBy)
	}
	if got[1].Username != "external@example.com" {
		t.Errorf("row 1 Username = %q, want external@example.com", got[1].Username)
	}
	if got[1].ScannedBy != nil {
		t.Errorf("row 1 ScannedBy = %v, want nil", got[1].ScannedBy)
	}
	if got[1].UserType != "External" {
		t.Errorf("row 1 UserType = %q, want External", got[1].UserType)
	}
}

func TestGetAttendeeSummary_Empty(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"agenda", "username", "scannedBy"})
	mock.ExpectQuery("SELECT").WillReturnRows(rows)

	got, err := repo.GetAttendeeSummary(context.Background())
	if err != nil {
		t.Fatalf("GetAttendeeSummary failed: %v", err)
	}
	if got == nil {
		t.Fatal("expected non-nil empty slice")
	}
	if len(got) != 0 {
		t.Errorf("expected 0 rows, got %d", len(got))
	}
}
