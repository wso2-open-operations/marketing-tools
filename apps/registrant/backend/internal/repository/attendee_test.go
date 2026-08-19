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

package repository

import (
	"context"
	"testing"

	"attendee-registration/internal/crypto"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestGetAttendeeSummary(t *testing.T) {
	repo, mock := newMockRepo(t)

	encInternal, err := crypto.Encrypt("Attendee@WSO2.COM")
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

	if got[0].Username != "Attendee@WSO2.COM" {
		t.Errorf("row 0 Username = %q, want Attendee@WSO2.COM", got[0].Username)
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
