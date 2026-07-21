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

//go:build integration

package repository

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"wso2-coin-backend/internal/models"
)

// attendeeProfileTestKey is a throwaway 32-byte AES-256 key used only by
// this test file; it has no relationship to any real PII_ENCRYPTION_KEY.
var attendeeProfileTestKey = mustDecodeTestKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

func newAttendeeFixture(t *testing.T, ctx context.Context, insert models.AttendeeInsert, idpUUID string) {
	t.Helper()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	if err := repo.Insert(ctx, insert, idpUUID); err != nil {
		t.Fatalf("failed to insert test attendee: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM attendees WHERE email = $1", insert.Email)
	})
}

func TestAttendeeProfileRepo_InsertAndGetByEmail_RoundTripsPlaintext(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())
	idpUUID := newUUID()

	insert := models.AttendeeInsert{
		Email:      email,
		Title:      "Principal Engineer",
		Company:    "WSO2",
		Country:    "Sri Lanka",
		FirstName:  "Ada",
		LastName:   "Lovelace",
		MemberID:   "00vVM00000abcdef",
		IsPartner:  true,
		ProfileURL: "https://example.com/ada.webp",
	}
	newAttendeeFixture(t, ctx, insert, idpUUID)

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.Email != email {
		t.Errorf("Email = %q, want %q", got.Email, email)
	}
	if got.IDPUUID != idpUUID {
		t.Errorf("IDPUUID = %q, want %q", got.IDPUUID, idpUUID)
	}
	if got.Title != "Principal Engineer" {
		t.Errorf("Title = %q, want %q", got.Title, "Principal Engineer")
	}
	if got.Company != "WSO2" {
		t.Errorf("Company = %q, want %q", got.Company, "WSO2")
	}
	if got.Country != "Sri Lanka" {
		t.Errorf("Country = %q, want %q", got.Country, "Sri Lanka")
	}
	if got.FirstName != "Ada" {
		t.Errorf("FirstName = %q, want %q", got.FirstName, "Ada")
	}
	if got.LastName != "Lovelace" {
		t.Errorf("LastName = %q, want %q", got.LastName, "Lovelace")
	}
	if !got.IsPartner {
		t.Errorf("IsPartner = false, want true")
	}
	if got.QRUri != "WCabcdef" {
		t.Errorf("QRUri = %q, want %q (00vVM00000 -> WC)", got.QRUri, "WCabcdef")
	}
}

func TestAttendeeProfileRepo_Insert_EncryptsPIIAtRest(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())

	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email:     email,
		Title:     "Secret Title",
		FirstName: "PlainFirst",
		LastName:  "PlainLast",
		MemberID:  "m-1",
	}, newUUID())

	var rawTitle, rawFirstName string
	err := testDB.QueryRow(ctx, "SELECT title, first_name FROM attendees WHERE email = $1", email).
		Scan(&rawTitle, &rawFirstName)
	if err != nil {
		t.Fatalf("failed to read raw row: %v", err)
	}
	if rawTitle == "Secret Title" {
		t.Errorf("title stored in plaintext, expected ciphertext")
	}
	if rawFirstName == "PlainFirst" {
		t.Errorf("first_name stored in plaintext, expected ciphertext")
	}

	// Sanity: repo.GetByEmail must still return the plaintext.
	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.Title != "Secret Title" || got.FirstName != "PlainFirst" {
		t.Errorf("decrypted fields = %q/%q, want %q/%q", got.Title, got.FirstName, "Secret Title", "PlainFirst")
	}
}

func TestAttendeeProfileRepo_Insert_UpsertsOnConflictingEmail(t *testing.T) {
	// Ports the old insertAttendeeQuery's ON DUPLICATE KEY UPDATE semantics
	// (an upsert), re-keyed on email instead of the old member_id PK.
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())
	firstUUID := newUUID()

	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email: email, Title: "First Title", FirstName: "First", MemberID: "m-first",
	}, firstUUID)

	secondUUID := newUUID()
	if err := repo.Insert(ctx, models.AttendeeInsert{
		Email: email, Title: "Second Title", FirstName: "Second", MemberID: "m-second",
	}, secondUUID); err != nil {
		t.Fatalf("second Insert (upsert) returned error: %v", err)
	}

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.Title != "Second Title" {
		t.Errorf("Title = %q, want %q (upserted)", got.Title, "Second Title")
	}
	if got.IDPUUID != secondUUID {
		t.Errorf("IDPUUID = %q, want %q (upserted)", got.IDPUUID, secondUUID)
	}
	if got.CreatedBy != firstUUID {
		t.Errorf("CreatedBy = %q, want %q (unchanged by the conflict update)", got.CreatedBy, firstUUID)
	}
	if got.UpdatedBy != secondUUID {
		t.Errorf("UpdatedBy = %q, want %q (set by the conflict update)", got.UpdatedBy, secondUUID)
	}
}

func TestAttendeeProfileRepo_GetByEmail_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	_, err := repo.GetByEmail(ctx, fmt.Sprintf("missing-%s@example.com", newUUID()))
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetByEmail error = %v, want ErrNotFound", err)
	}
}

func TestAttendeeProfileRepo_GetByUUID_RoundTrips(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())
	idpUUID := newUUID()

	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email:     email,
		FirstName: "Alan",
		LastName:  "Turing",
		MemberID:  "m-2",
	}, idpUUID)

	got, err := repo.GetByUUID(ctx, idpUUID)
	if err != nil {
		t.Fatalf("GetByUUID returned error: %v", err)
	}
	if got.Email != email {
		t.Errorf("Email = %q, want %q", got.Email, email)
	}
	if got.FirstName != "Alan" {
		t.Errorf("FirstName = %q, want %q", got.FirstName, "Alan")
	}
}

func TestAttendeeProfileRepo_GetByUUID_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	_, err := repo.GetByUUID(ctx, newUUID())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetByUUID error = %v, want ErrNotFound", err)
	}
}

func TestAttendeeProfileRepo_PatchByEmail_UpdatesOnlyProvidedFields(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())

	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email:     email,
		Title:     "Old Title",
		Company:   "Old Company",
		FirstName: "OldFirst",
		LastName:  "OldLast",
		MemberID:  "m-3",
	}, newUUID())

	updatedTitle := "New Title"
	updatedBy := newUUID()
	err := repo.PatchByEmail(ctx, email, models.AttendeePatch{Title: &updatedTitle}, updatedBy)
	if err != nil {
		t.Fatalf("PatchByEmail returned error: %v", err)
	}

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.Title != "New Title" {
		t.Errorf("Title = %q, want %q", got.Title, "New Title")
	}
	if got.Company != "Old Company" {
		t.Errorf("Company = %q, want %q (unchanged)", got.Company, "Old Company")
	}
	if got.FirstName != "OldFirst" {
		t.Errorf("FirstName = %q, want %q (unchanged)", got.FirstName, "OldFirst")
	}
	if got.UpdatedBy != updatedBy {
		t.Errorf("UpdatedBy = %q, want %q", got.UpdatedBy, updatedBy)
	}
}

func TestAttendeeProfileRepo_PatchByEmail_NotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	title := "New Title"
	err := repo.PatchByEmail(ctx, fmt.Sprintf("missing-%s@example.com", newUUID()), models.AttendeePatch{Title: &title}, newUUID())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("PatchByEmail error = %v, want ErrNotFound", err)
	}
}

func TestAttendeeProfileRepo_Search_ExcludesSelfAndFiltersByUUID(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	selfUUID := newUUID()
	targetUUID := newUUID()
	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email: fmt.Sprintf("self-%s@example.com", newUUID()), FirstName: "Self", MemberID: "m-self",
	}, selfUUID)
	newAttendeeFixture(t, ctx, models.AttendeeInsert{
		Email: fmt.Sprintf("target-%s@example.com", newUUID()), FirstName: "Target", MemberID: "m-target",
	}, targetUUID)

	result, err := repo.Search(ctx, models.AttendeeSearchFilter{UUID: targetUUID, StartIndex: 1, ItemsPerPage: 10}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if result.TotalResults != 1 {
		t.Fatalf("TotalResults = %d, want 1", result.TotalResults)
	}
	if len(result.Attendees) != 1 || result.Attendees[0].IDPUUID != targetUUID {
		t.Fatalf("Attendees = %+v, want exactly the target attendee", result.Attendees)
	}

	// Searching for self must never return self, even with no uuid filter.
	self, err := repo.Search(ctx, models.AttendeeSearchFilter{StartIndex: 1, ItemsPerPage: 1000}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	for _, a := range self.Attendees {
		if a.IDPUUID == selfUUID {
			t.Errorf("Search results include the excluded self uuid %q", selfUUID)
		}
	}
}

func TestAttendeeQRFromMemberID(t *testing.T) {
	cases := []struct {
		memberID string
		want     string
	}{
		{"00vVM00000abcdef", "WCabcdef"},
		{"00vVM0000000vVM00000", "WC00vVM00000"}, // only the first occurrence is replaced
		{"noprefixhere", "noprefixhere"},
		{"", ""},
	}
	for _, c := range cases {
		if got := attendeeQRFromMemberID(c.memberID); got != c.want {
			t.Errorf("attendeeQRFromMemberID(%q) = %q, want %q", c.memberID, got, c.want)
		}
	}
}
