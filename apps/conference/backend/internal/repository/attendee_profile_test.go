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
	"time"

	"wso2-coin-backend/internal/models"
)

// attendeeProfileTestKey is a throwaway 32-byte AES-256 key used only by
// this test file; it has no relationship to any real PII_ENCRYPTION_KEY.
var attendeeProfileTestKey = mustDecodeTestKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

// zeroUUID is the lowest possible attendees.id, so a cursor carrying it is
// ordered purely by its timestamp.
const zeroUUID = "00000000-0000-0000-0000-000000000000"

// searchStartCursor returns a keyset cursor pinned to the database's clock at
// the moment it is called, so any Search passed it can only ever reach rows
// this test creates afterwards.
//
// Search's ordering is (created_at, id) and its text match runs in Go *after*
// decryption, so an unbounded or text-filtered Search walks the whole shared
// staging table and decrypts every real attendee with this file's throwaway
// key -- the GCM tag fails and the error takes down the whole page. That is
// audit S3 one table over: a harness fault, not a product one. Speakers scope
// the same problem away with a fixture-created eventId (speaker_test.go);
// attendees have no such column, so the keyset position is the scope.
//
// The instant comes from NOW() on the server rather than time.Now() here:
// created_at defaults to the DB clock, and any skew against the test
// machine's would either strand the fixtures outside the range or let real
// rows back into it.
func searchStartCursor(t *testing.T, ctx context.Context) string {
	t.Helper()
	var now time.Time
	if err := testDB.QueryRow(ctx, "SELECT NOW()").Scan(&now); err != nil {
		t.Fatalf("reading the database clock failed: %v", err)
	}
	return encodeAttendeeCursor(now, zeroUUID)
}

func newAttendeeFixture(t *testing.T, ctx context.Context, email string, insert models.AttendeeInsert, idpUUID string) {
	t.Helper()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	if err := repo.Insert(ctx, insert, email, idpUUID); err != nil {
		t.Fatalf("failed to insert test attendee: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM attendees WHERE email = $1", email)
	})
}

func TestAttendeeProfileRepo_InsertAndGetByEmail_RoundTripsPlaintext(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())
	idpUUID := newUUID()

	insert := models.AttendeeInsert{
		Title:      "Principal Engineer",
		Company:    "WSO2",
		Country:    "Sri Lanka",
		FirstName:  "Ada",
		LastName:   "Lovelace",
		MemberID:   "00vVM00000abcdef",
		IsPartner:  true,
		ProfileURL: "https://example.com/ada.webp",
	}
	newAttendeeFixture(t, ctx, email, insert, idpUUID)

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

	newAttendeeFixture(t, ctx, email, models.AttendeeInsert{
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

func TestAttendeeProfileRepo_Insert_SelfReRegistrationIsIdempotent(t *testing.T) {
	// The upsert exists so an attendee can re-register (refresh their own
	// profile) without a conflict. Same email, same idp_uuid -> update.
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("attendee-%s@example.com", newUUID())
	idpUUID := newUUID()

	newAttendeeFixture(t, ctx, email, models.AttendeeInsert{
		Title: "First Title", FirstName: "First", LastName: "Last", MemberID: "m-" + newUUID(),
	}, idpUUID)

	if err := repo.Insert(ctx, models.AttendeeInsert{
		Title: "Second Title", FirstName: "Second", LastName: "Last", MemberID: "m2-" + newUUID(),
	}, email, idpUUID); err != nil {
		t.Fatalf("re-registration Insert returned error: %v", err)
	}

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.Title != "Second Title" {
		t.Errorf("Title = %q, want %q (upserted)", got.Title, "Second Title")
	}
	if got.IDPUUID != idpUUID {
		t.Errorf("IDPUUID = %q, want %q (unchanged)", got.IDPUUID, idpUUID)
	}
	if got.CreatedBy != idpUUID {
		t.Errorf("CreatedBy = %q, want %q (unchanged by the conflict update)", got.CreatedBy, idpUUID)
	}
	if got.UpdatedBy != idpUUID {
		t.Errorf("UpdatedBy = %q, want %q (set by the conflict update)", got.UpdatedBy, idpUUID)
	}
}

func TestAttendeeProfileRepo_Insert_HijackAttemptIsNoOp(t *testing.T) {
	// Audit A2. Before the scoped upsert, a second caller's Insert on an
	// existing email rebound that row's idp_uuid to the attacker and
	// overwrote every PII column, member_id (served as qrUri, the check-in
	// credential) included.
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("victim-%s@example.com", newUUID())
	victimUUID := newUUID()
	victimMemberID := "00vVM00000" + newUUID()[:8]

	newAttendeeFixture(t, ctx, email, models.AttendeeInsert{
		Title: "Victim Title", FirstName: "Victim", LastName: "Row", MemberID: victimMemberID,
	}, victimUUID)

	attackerUUID := newUUID()
	err := repo.Insert(ctx, models.AttendeeInsert{
		Title: "Attacker Title", FirstName: "Attacker", LastName: "Row", MemberID: "attacker-" + newUUID(),
	}, email, attackerUUID)
	if !errors.Is(err, ErrEmailOwnedByAnother) {
		t.Fatalf("Insert error = %v, want ErrEmailOwnedByAnother", err)
	}

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.IDPUUID != victimUUID {
		t.Errorf("IDPUUID = %q, want %q (the victim's row must not be rebound)", got.IDPUUID, victimUUID)
	}
	if got.Title != "Victim Title" || got.FirstName != "Victim" {
		t.Errorf("PII = %q/%q, want %q/%q (unchanged)", got.Title, got.FirstName, "Victim Title", "Victim")
	}
	if got.MemberID != victimMemberID {
		t.Errorf("MemberID = %q, want %q (the check-in credential must not be overwritten)", got.MemberID, victimMemberID)
	}
}

func TestAttendeeProfileRepo_Insert_ClaimsRowImportedWithNoIDPUUID(t *testing.T) {
	// migration 003 leaves idp_uuid NULL for rows imported from registration;
	// the attendee's first login binds it. The scoped upsert must still allow
	// that, or every pre-imported attendee is locked out of their own row.
	//
	// The imported row already carries the member_id the registration import
	// assigned, and payload.MemberID is optional, so the claiming POST need not
	// repeat it. member_id backs qrUri, the check-in credential, so an omitted
	// memberId must leave the stored one alone rather than NULL it.
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	email := fmt.Sprintf("imported-%s@example.com", newUUID())
	importedMemberID := "00vVM00000" + newUUID()[:8]

	if _, err := testDB.Exec(ctx,
		"INSERT INTO attendees (email, idp_uuid, member_id) VALUES ($1, NULL, $2)",
		email, importedMemberID); err != nil {
		t.Fatalf("seeding imported row failed: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM attendees WHERE email = $1", email)
	})

	idpUUID := newUUID()
	if err := repo.Insert(ctx, models.AttendeeInsert{
		FirstName: "Claimed", LastName: "Row",
	}, email, idpUUID); err != nil {
		t.Fatalf("claiming Insert returned error: %v", err)
	}

	got, err := repo.GetByEmail(ctx, email)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if got.IDPUUID != idpUUID {
		t.Errorf("IDPUUID = %q, want %q (first login binds the imported row)", got.IDPUUID, idpUUID)
	}
	if got.MemberID != importedMemberID {
		t.Errorf("MemberID = %q, want %q (an omitted memberId must not clear the stored one)", got.MemberID, importedMemberID)
	}
	if wantQR := attendeeQRFromMemberID(importedMemberID); got.QRUri != wantQR {
		t.Errorf("QRUri = %q, want %q (the check-in credential must survive the claim)", got.QRUri, wantQR)
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

	newAttendeeFixture(t, ctx, email, models.AttendeeInsert{
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

	newAttendeeFixture(t, ctx, email, models.AttendeeInsert{
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

	startCursor := searchStartCursor(t, ctx)
	selfUUID := newUUID()
	targetUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self",
	}, selfUUID)
	newAttendeeFixture(t, ctx, fmt.Sprintf("target-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Target",
	}, targetUUID)

	result, err := repo.Search(ctx, models.AttendeeSearchFilter{UUID: targetUUID, Limit: 10}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if len(result.Items) != 1 || result.Items[0].IDPUUID != targetUUID {
		t.Fatalf("Items = %+v, want exactly the target attendee", result.Items)
	}
	if result.Page.NextCursor != "" {
		t.Errorf("NextCursor = %q, want empty (single result fits one page)", result.Page.NextCursor)
	}

	// Searching for self must never return self, even with no uuid filter. The
	// start cursor bounds this unfiltered listing to the two rows above.
	self, err := repo.Search(ctx, models.AttendeeSearchFilter{Limit: 100, Cursor: startCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	// The target proves the range isn't trivially empty, which would make the
	// self-exclusion assertion below pass for the wrong reason.
	sawTarget := false
	for _, a := range self.Items {
		if a.IDPUUID == selfUUID {
			t.Errorf("Search results include the excluded self uuid %q", selfUUID)
		}
		if a.IDPUUID == targetUUID {
			sawTarget = true
		}
	}
	if !sawTarget {
		t.Errorf("unfiltered search over this test's own rows missed the target %q", targetUUID)
	}
}

func TestAttendeeProfileRepo_Search_FiltersByQueryOverEncryptedFields(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	startCursor := searchStartCursor(t, ctx)
	selfUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self",
	}, selfUUID)

	// Three attendees that each match a query on a different encrypted column:
	// name, company, title. All decrypt-then-match in Go.
	byName := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("a-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Grace", LastName: "TddHopperUnique",
	}, byName)
	byCompany := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("b-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Bob", Company: "TddAcmeUniqueCorp",
	}, byCompany)
	byTitle := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("c-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Carol", Title: "TddPrincipalUnique",
	}, byTitle)

	cases := []struct {
		query    string
		wantUUID string
	}{
		{"tddhopperunique", byName},     // case-insensitive, matches last name
		{"TddAcmeUnique", byCompany},    // matches company substring
		{"tddprincipalunique", byTitle}, // matches title
	}
	for _, tc := range cases {
		result, err := repo.Search(ctx, models.AttendeeSearchFilter{Query: tc.query, Limit: 50, Cursor: startCursor}, selfUUID)
		if err != nil {
			t.Fatalf("Search(%q) returned error: %v", tc.query, err)
		}
		if len(result.Items) != 1 || result.Items[0].IDPUUID != tc.wantUUID {
			t.Errorf("Search(%q) = %+v, want exactly the attendee %s", tc.query, result.Items, tc.wantUUID)
		}
	}

	// A query matching none of the fixtures returns an empty (non-nil) slice.
	none, err := repo.Search(ctx, models.AttendeeSearchFilter{Query: "no-such-attendee-zzz", Limit: 50, Cursor: startCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if none.Items == nil || len(none.Items) != 0 {
		t.Errorf("Items = %v, want a non-nil empty slice", none.Items)
	}
}

func TestAttendeeProfileRepo_Search_CursorPaginationIsStableAndComplete(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	startCursor := searchStartCursor(t, ctx)
	selfUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self",
	}, selfUUID)

	// Five attendees sharing a unique company token so the search is isolated
	// from any other rows regardless of what else exists in the shared DB.
	const companyToken = "TddPaginationUniqueCo"
	want := make(map[string]bool)
	for i := 0; i < 5; i++ {
		u := newUUID()
		want[u] = true
		newAttendeeFixture(t, ctx, fmt.Sprintf("page-%s@example.com", newUUID()), models.AttendeeInsert{
			Company: companyToken,
		}, u)
	}

	seen := make(map[string]bool)
	// Paging starts at the test's own start position, not at the head of the
	// table: the walk that a text query forces would otherwise decrypt every
	// real staging attendee on the way to the fixtures.
	cursor := startCursor
	pages := 0
	for {
		pages++
		if pages > 10 {
			t.Fatalf("pagination did not terminate; seen=%v", seen)
		}
		result, err := repo.Search(ctx, models.AttendeeSearchFilter{
			Query: companyToken, Limit: 2, Cursor: cursor,
		}, selfUUID)
		if err != nil {
			t.Fatalf("Search returned error: %v", err)
		}
		if len(result.Items) > 2 {
			t.Fatalf("page returned %d items, want <= limit 2", len(result.Items))
		}
		for _, a := range result.Items {
			if seen[a.IDPUUID] {
				t.Errorf("attendee %s returned on more than one page", a.IDPUUID)
			}
			seen[a.IDPUUID] = true
		}
		if result.Page.NextCursor == "" {
			break
		}
		cursor = result.Page.NextCursor
	}

	if len(seen) != len(want) {
		t.Errorf("paged over %d attendees, want %d", len(seen), len(want))
	}
	for u := range want {
		if !seen[u] {
			t.Errorf("attendee %s missing from paged results", u)
		}
	}
}

func TestAttendeeProfileRepo_Search_UnfilteredPageIsBoundedAndReportsMore(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	startCursor := searchStartCursor(t, ctx)
	selfUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self",
	}, selfUUID)
	for i := 0; i < 3; i++ {
		newAttendeeFixture(t, ctx, fmt.Sprintf("bounded-%s@example.com", newUUID()), models.AttendeeInsert{}, newUUID())
	}

	// The no-query path bounds the read with a SQL LIMIT of limit+1. The +1 is
	// what tells us another page exists, so it has to survive: a LIMIT of exactly
	// `limit` would silently strand the remaining rows with an empty NextCursor.
	//
	// This is the one test that is *about* the unfiltered whole-table path, so
	// it cannot be scoped by a filter. The start cursor keeps the semantics
	// intact -- it is still the no-query branch, still bounded by SQL LIMIT --
	// while making the three fixtures above the only rows in range, which is
	// also what turns "another page exists" into a deterministic assertion
	// instead of one riding on the shared table being non-empty.
	first, err := repo.Search(ctx, models.AttendeeSearchFilter{Limit: 2, Cursor: startCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if len(first.Items) != 2 {
		t.Fatalf("Items = %d, want exactly the limit of 2", len(first.Items))
	}
	if first.Page.NextCursor == "" {
		t.Fatal("NextCursor is empty, want a cursor since a third attendee is in range")
	}

	second, err := repo.Search(ctx, models.AttendeeSearchFilter{Limit: 2, Cursor: first.Page.NextCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if len(second.Items) != 1 {
		t.Errorf("second page = %d items, want the 1 remaining fixture", len(second.Items))
	}
	if second.Page.NextCursor != "" {
		t.Errorf("NextCursor = %q, want empty on the last page", second.Page.NextCursor)
	}
	seen := make(map[string]bool, len(first.Items))
	for _, a := range first.Items {
		seen[a.ID] = true
	}
	for _, a := range second.Items {
		if seen[a.ID] {
			t.Errorf("attendee %s appeared on both pages", a.ID)
		}
	}
}

func TestAttendeeProfileRepo_Search_InvalidCursorReturnsErrInvalidCursor(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	_, err := repo.Search(ctx, models.AttendeeSearchFilter{Cursor: "!!!not-base64!!!", Limit: 10}, newUUID())
	if !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("Search error = %v, want ErrInvalidCursor", err)
	}
}

func TestAttendeeProfileRepo_Search_ExcludesAttendeesWithNoIDPUUID(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	startCursor := searchStartCursor(t, ctx)
	selfUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self",
	}, selfUUID)

	// A control row that shares the orphan's company token and *does* have an
	// idp_uuid. Without it both assertions below would pass on an empty result
	// set, proving nothing about the IS NOT NULL filter.
	controlUUID := newUUID()

	// The repo's Insert always writes the caller's JWT sub, so it can't produce a
	// NULL idp_uuid; a registration import can, so write the row directly. company
	// is stored as ciphertext and the query match decrypts it, so the token has to
	// go in encrypted for the search to have any chance of matching this row --
	// otherwise the test would pass whether or not the row was correctly excluded.
	const companyToken = "TddNoUuidUniqueCo"
	newAttendeeFixture(t, ctx, fmt.Sprintf("control-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Control", Company: companyToken,
	}, controlUUID)

	encryptedCompany, err := repo.encrypt(companyToken)
	if err != nil {
		t.Fatalf("encrypt returned error: %v", err)
	}
	orphanEmail := fmt.Sprintf("no-uuid-%s@example.com", newUUID())
	if _, err := testDB.Exec(ctx,
		`INSERT INTO attendees (email, idp_uuid, company) VALUES ($1, NULL, $2)`,
		orphanEmail, encryptedCompany,
	); err != nil {
		t.Fatalf("inserting attendee with NULL idp_uuid returned error: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM attendees WHERE email = $1", orphanEmail)
	})

	// A row with no idp_uuid has no uuid to connect to, so it must not surface --
	// not via a text query, and not via an unfiltered listing either.
	result, err := repo.Search(ctx, models.AttendeeSearchFilter{Query: companyToken, Limit: 50, Cursor: startCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if len(result.Items) != 1 || result.Items[0].IDPUUID != controlUUID {
		t.Errorf("Search(%q) = %+v, want only the control row (the orphan has no idp_uuid)", companyToken, result.Items)
	}

	all, err := repo.Search(ctx, models.AttendeeSearchFilter{Limit: 100, Cursor: startCursor}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	sawControl := false
	for _, a := range all.Items {
		if a.Email == orphanEmail {
			t.Errorf("unfiltered search returned attendee %q, which has no idp_uuid", orphanEmail)
		}
		if a.IDPUUID == controlUUID {
			sawControl = true
		}
	}
	if !sawControl {
		t.Errorf("unfiltered search over this test's own rows missed the control %q", controlUUID)
	}
}

func TestAttendeeProfileRepo_Search_OmitsMemberIDAndQRUri(t *testing.T) {
	// Audit P2. qrUri is the check-in credential and neither field is in the
	// openapi Attendee schema; the directory search of every other attendee is
	// the last place they belong. GET /attendees/me still carries the caller's.
	ctx := context.Background()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)

	selfUUID := newUUID()
	targetUUID := newUUID()
	newAttendeeFixture(t, ctx, fmt.Sprintf("self-%s@example.com", newUUID()), models.AttendeeInsert{
		FirstName: "Self", LastName: "Caller",
	}, selfUUID)
	targetEmail := fmt.Sprintf("target-%s@example.com", newUUID())
	newAttendeeFixture(t, ctx, targetEmail, models.AttendeeInsert{
		FirstName: "Target", LastName: "Row", MemberID: "00vVM00000" + newUUID()[:8],
	}, targetUUID)

	result, err := repo.Search(ctx, models.AttendeeSearchFilter{UUID: targetUUID, Limit: 10}, selfUUID)
	if err != nil {
		t.Fatalf("Search returned error: %v", err)
	}
	if len(result.Items) != 1 {
		t.Fatalf("Items = %+v, want exactly the target attendee", result.Items)
	}
	got := result.Items[0]
	if got.MemberID != "" {
		t.Errorf("MemberID = %q, want empty in search results", got.MemberID)
	}
	if got.QRUri != "" {
		t.Errorf("QRUri = %q, want empty in search results (it is a check-in credential)", got.QRUri)
	}
	if got.Email != targetEmail {
		t.Errorf("Email = %q, want %q (email stays: connections key off it)", got.Email, targetEmail)
	}

	// The caller's own row still carries both.
	self, err := repo.GetByEmail(ctx, targetEmail)
	if err != nil {
		t.Fatalf("GetByEmail returned error: %v", err)
	}
	if self.QRUri == "" {
		t.Errorf("GetByEmail QRUri = empty, want the attendee's own QR credential")
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
