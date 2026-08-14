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

	"github.com/DATA-DOG/go-sqlmock"
)

func TestGetAttendeeSummary(t *testing.T) {
	repo, mock := newMockRepo(t)

	rows := sqlmock.NewRows([]string{"agenda", "username", "scannedBy", "userType"}).
		AddRow("Day 1", "attendee@wso2.com", "admin@wso2.com", "Internal").
		AddRow("Day 1", "external@example.com", nil, "External")
	mock.ExpectQuery("SELECT").WithArgs("%@wso2.com%").WillReturnRows(rows)

	got, err := repo.GetAttendeeSummary(context.Background())
	if err != nil {
		t.Fatalf("GetAttendeeSummary failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(got))
	}

	if got[0].ScannedBy == nil || *got[0].ScannedBy != "admin@wso2.com" {
		t.Errorf("row 0 ScannedBy = %v, want admin@wso2.com", got[0].ScannedBy)
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

	rows := sqlmock.NewRows([]string{"agenda", "username", "scannedBy", "userType"})
	mock.ExpectQuery("SELECT").WithArgs("%@wso2.com%").WillReturnRows(rows)

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
