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

func newConnectionAttendeeFixture(t *testing.T, ctx context.Context, firstName, lastName string) (idpUUID string) {
	t.Helper()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	idpUUID = newUUID()
	err := repo.Insert(ctx, models.AttendeeInsert{
		FirstName: firstName,
		LastName:  lastName,
		MemberID:  "m-" + newUUID(),
	}, fmt.Sprintf("%s-%s@example.com", firstName, newUUID()), idpUUID)
	if err != nil {
		t.Fatalf("failed to insert test attendee: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM attendees WHERE idp_uuid = $1", idpUUID)
	})
	return idpUUID
}

func newConnectionRepo() *ConnectionRepo {
	return NewConnectionRepo(testDB, NewAttendeeProfileRepo(testDB, attendeeProfileTestKey))
}

// cleanupConnection drops whatever row the pair ends up with, in either
// direction. It is registered before the row exists because several tests
// delete and re-request the same pair, so the id is not stable enough to
// clean up by.
func cleanupConnection(t *testing.T, a, b string) {
	t.Helper()
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(),
			`DELETE FROM user_connection
			 WHERE (requester_id = $1 AND addressee_id = $2) OR (requester_id = $2 AND addressee_id = $1)`,
			a, b)
	})
}

// countConnectionRows counts the stored rows for a pair. Several tests assert
// on it rather than on the API surface, because the bugs the redesign closes
// (mirror rows, orphan rows) are invisible from Get -- an orphan row has no
// attendee to join against, so it silently drops out of the response.
func countConnectionRows(t *testing.T, ctx context.Context, a, b string) int {
	t.Helper()
	var count int
	err := testDB.QueryRow(ctx,
		`SELECT COUNT(*) FROM user_connection
		 WHERE (requester_id = $1 AND addressee_id = $2) OR (requester_id = $2 AND addressee_id = $1)`,
		a, b,
	).Scan(&count)
	if err != nil {
		t.Fatalf("failed to count user_connection rows: %v", err)
	}
	return count
}

func connectionStateByID(t *testing.T, ctx context.Context, id string) string {
	t.Helper()
	var state string
	if err := testDB.QueryRow(ctx, "SELECT state FROM user_connection WHERE id = $1", id).Scan(&state); err != nil {
		t.Fatalf("failed to read state of connection %s: %v", id, err)
	}
	return state
}

// connectionAttendeeEmail reads back the address newConnectionAttendeeFixture
// generated. The helper returns only the uuid, and every other test in this
// file is happy with that, so the email is fetched here rather than widening a
// signature eleven callers depend on.
func connectionAttendeeEmail(t *testing.T, ctx context.Context, idpUUID string) string {
	t.Helper()
	var email string
	if err := testDB.QueryRow(ctx, "SELECT email FROM attendees WHERE idp_uuid = $1", idpUUID).Scan(&email); err != nil {
		t.Fatalf("failed to read the email of attendee %s: %v", idpUUID, err)
	}
	if email == "" {
		t.Fatalf("attendee %s has no email, so this test could not tell a leak from an empty column", idpUUID)
	}
	return email
}

func TestConnectionRepo_Get_PendingWithholdsEmailFromBothParties(t *testing.T) {
	// The disclosure this test exists for: a pending row is joined into *both*
	// parties' responses, so populating the address unconditionally handed the
	// recipient's email to whoever sent the request, before the recipient had
	// done anything at all -- and handed the sender's back the same way.
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice16", "Sender")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob16", "Receiver")
	cleanupConnection(t, alice, bob)

	if _, err := repo.Request(ctx, alice, bob); err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	// Read the addresses back so the assertions below cannot pass merely
	// because the fixtures had no email to leak.
	aliceEmail := connectionAttendeeEmail(t, ctx, alice)
	bobEmail := connectionAttendeeEmail(t, ctx, bob)

	aliceView, err := repo.Get(ctx, alice)
	if err != nil {
		t.Fatalf("Get(alice) returned error: %v", err)
	}
	if len(aliceView.RequestsSent) != 1 {
		t.Fatalf("alice.RequestsSent = %+v, want exactly one pending request", aliceView.RequestsSent)
	}
	sent := aliceView.RequestsSent[0]
	if sent.Email != "" {
		t.Errorf("alice.RequestsSent[0].Email = %q, want empty -- bob has not accepted (his address is %q)", sent.Email, bobEmail)
	}
	// The rest of the enrichment must survive: this withholds the address
	// specifically, not the whole profile, or the requests list would be
	// unusable.
	if sent.Name != "Bob16 Receiver" {
		t.Errorf("alice.RequestsSent[0].Name = %q, want %q -- only the email is withheld", sent.Name, "Bob16 Receiver")
	}
	if sent.UserID != bob || sent.Status != "pending" {
		t.Errorf("alice.RequestsSent[0] = %+v, want bob's uuid and a pending status", sent)
	}

	bobView, err := repo.Get(ctx, bob)
	if err != nil {
		t.Fatalf("Get(bob) returned error: %v", err)
	}
	if len(bobView.RequestsReceived) != 1 {
		t.Fatalf("bob.RequestsReceived = %+v, want exactly one pending request", bobView.RequestsReceived)
	}
	received := bobView.RequestsReceived[0]
	if received.Email != "" {
		t.Errorf("bob.RequestsReceived[0].Email = %q, want empty -- he has not accepted yet (alice's address is %q)", received.Email, aliceEmail)
	}
	if received.Name != "Alice16 Sender" {
		t.Errorf("bob.RequestsReceived[0].Name = %q, want %q -- only the email is withheld", received.Name, "Alice16 Sender")
	}
}

func TestConnectionRepo_Get_AcceptedReleasesEmailToBothParties(t *testing.T) {
	// The other side of the gate. Exchanging contact details is what accepting
	// *is*, so a fix that simply stopped returning the column would break the
	// feature rather than secure it.
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice17", "Sender")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob17", "Receiver")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if _, err := repo.Accept(ctx, pending.ID, bob); err != nil {
		t.Fatalf("Accept returned error: %v", err)
	}

	for _, party := range []struct {
		name, self, wantEmail string
	}{
		{"alice", alice, connectionAttendeeEmail(t, ctx, bob)},
		{"bob", bob, connectionAttendeeEmail(t, ctx, alice)},
	} {
		view, err := repo.Get(ctx, party.self)
		if err != nil {
			t.Fatalf("Get(%s) returned error: %v", party.name, err)
		}
		if len(view.Connections) != 1 {
			t.Fatalf("%s.Connections = %+v, want exactly one accepted connection", party.name, view.Connections)
		}
		if got := view.Connections[0].Email; got != party.wantEmail {
			t.Errorf("%s.Connections[0].Email = %q, want the other party's address %q", party.name, got, party.wantEmail)
		}
	}
}

func TestConnectionRepo_Request_CreatesPendingVisibleToBothParties(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice", "Sender")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob", "Receiver")
	cleanupConnection(t, alice, bob)

	conn, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if conn.State != models.ConnectionPending {
		t.Errorf("Request state = %q, want %q", conn.State, models.ConnectionPending)
	}
	if conn.RequesterID != alice || conn.AddresseeID != bob {
		t.Errorf("Request parties = (%q -> %q), want (%q -> %q)", conn.RequesterID, conn.AddresseeID, alice, bob)
	}

	aliceView, err := repo.Get(ctx, alice)
	if err != nil {
		t.Fatalf("Get(alice) returned error: %v", err)
	}
	if len(aliceView.RequestsSent) != 1 || aliceView.RequestsSent[0].UserID != bob {
		t.Fatalf("alice.RequestsSent = %+v, want exactly bob", aliceView.RequestsSent)
	}
	if len(aliceView.RequestsReceived) != 0 || len(aliceView.Connections) != 0 {
		t.Errorf("alice's other buckets = %+v / %+v, want both empty", aliceView.RequestsReceived, aliceView.Connections)
	}
	sent := aliceView.RequestsSent[0]
	if sent.Name != "Bob Receiver" {
		t.Errorf("alice.RequestsSent[0].Name = %q, want %q", sent.Name, "Bob Receiver")
	}
	if sent.Status != "pending" {
		t.Errorf("alice.RequestsSent[0].Status = %q, want %q", sent.Status, "pending")
	}
	// Without ConnectionID the client has no handle for accept/delete.
	if sent.ConnectionID != conn.ID {
		t.Errorf("alice.RequestsSent[0].ConnectionID = %q, want %q", sent.ConnectionID, conn.ID)
	}

	bobView, err := repo.Get(ctx, bob)
	if err != nil {
		t.Fatalf("Get(bob) returned error: %v", err)
	}
	if len(bobView.RequestsReceived) != 1 || bobView.RequestsReceived[0].UserID != alice {
		t.Fatalf("bob.RequestsReceived = %+v, want exactly alice", bobView.RequestsReceived)
	}
	received := bobView.RequestsReceived[0]
	if received.Name != "Alice Sender" {
		t.Errorf("bob.RequestsReceived[0].Name = %q, want %q", received.Name, "Alice Sender")
	}
	if received.ConnectionID != conn.ID {
		t.Errorf("bob.RequestsReceived[0].ConnectionID = %q, want %q", received.ConnectionID, conn.ID)
	}
	if len(bobView.RequestsSent) != 0 || len(bobView.Connections) != 0 {
		t.Errorf("bob's other buckets = %+v / %+v, want both empty", bobView.RequestsSent, bobView.Connections)
	}
}

func TestConnectionRepo_Request_RepeatedRequestIsIdempotent(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice2", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob2", "Y")
	cleanupConnection(t, alice, bob)

	first, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("first Request returned error: %v", err)
	}
	// A retried request (double tap, client retry) must not be an error and
	// must not produce a second row -- ON CONFLICT DO NOTHING plus the
	// read-back fallback.
	second, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("second Request returned error: %v", err)
	}
	if second.ID != first.ID {
		t.Errorf("second Request id = %q, want the first id %q", second.ID, first.ID)
	}
	if n := countConnectionRows(t, ctx, alice, bob); n != 1 {
		t.Errorf("row count = %d, want exactly 1", n)
	}
}

func TestConnectionRepo_Request_ReverseDirectionReturnsExistingRow(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice3", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob3", "Y")
	cleanupConnection(t, alice, bob)

	first, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request(alice -> bob) returned error: %v", err)
	}
	// The mirror-row bug: under the old directional key this wrote a second
	// (bob, alice) row for the same relationship. The pair unique constraint
	// now collapses it onto the existing row, requester unchanged -- if bob
	// became the requester he could then "accept" alice's request himself.
	mirror, err := repo.Request(ctx, bob, alice)
	if err != nil {
		t.Fatalf("Request(bob -> alice) returned error: %v", err)
	}
	if mirror.ID != first.ID {
		t.Errorf("reverse Request id = %q, want the existing id %q", mirror.ID, first.ID)
	}
	if mirror.RequesterID != alice || mirror.AddresseeID != bob {
		t.Errorf("reverse Request parties = (%q -> %q), want the original (%q -> %q)",
			mirror.RequesterID, mirror.AddresseeID, alice, bob)
	}
	if n := countConnectionRows(t, ctx, alice, bob); n != 1 {
		t.Errorf("row count = %d, want exactly 1 (no mirror row)", n)
	}
}

func TestConnectionRepo_Request_UnknownAddresseeWritesNothing(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice4", "X")
	ghost := newUUID()
	cleanupConnection(t, alice, ghost)

	if _, err := repo.Request(ctx, alice, ghost); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Request returned %v, want ErrNotFound", err)
	}
	// The orphan-row regression: the old code inserted first and validated
	// afterwards, so a 404 still left a row behind that no Get could ever
	// surface (there is no attendee row to join against).
	if n := countConnectionRows(t, ctx, alice, ghost); n != 0 {
		t.Errorf("row count = %d, want 0 -- a 404 must write nothing", n)
	}
}

func TestConnectionRepo_Request_SelfReturnsErrSelfConnection(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice5", "X")
	cleanupConnection(t, alice, alice)

	if _, err := repo.Request(ctx, alice, alice); !errors.Is(err, ErrSelfConnection) {
		t.Fatalf("Request returned %v, want ErrSelfConnection", err)
	}
	if n := countConnectionRows(t, ctx, alice, alice); n != 0 {
		t.Errorf("row count = %d, want 0", n)
	}
}

func TestConnectionRepo_Accept_ByAddresseeConnectsBothParties(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice6", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob6", "Y")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	accepted, err := repo.Accept(ctx, pending.ID, bob)
	if err != nil {
		t.Fatalf("Accept returned error: %v", err)
	}
	if accepted.State != models.ConnectionAccepted {
		t.Errorf("Accept state = %q, want %q", accepted.State, models.ConnectionAccepted)
	}

	for _, party := range []struct {
		name, self, other string
	}{{"alice", alice, bob}, {"bob", bob, alice}} {
		view, err := repo.Get(ctx, party.self)
		if err != nil {
			t.Fatalf("Get(%s) returned error: %v", party.name, err)
		}
		if len(view.Connections) != 1 || view.Connections[0].UserID != party.other {
			t.Errorf("%s.Connections = %+v, want exactly the other party", party.name, view.Connections)
			continue
		}
		if view.Connections[0].Status != "accepted" {
			t.Errorf("%s.Connections[0].Status = %q, want %q", party.name, view.Connections[0].Status, "accepted")
		}
		if view.Connections[0].ConnectionID != pending.ID {
			t.Errorf("%s.Connections[0].ConnectionID = %q, want %q", party.name, view.Connections[0].ConnectionID, pending.ID)
		}
		if len(view.RequestsSent) != 0 || len(view.RequestsReceived) != 0 {
			t.Errorf("%s still has request buckets %+v / %+v, want both empty once accepted",
				party.name, view.RequestsSent, view.RequestsReceived)
		}
	}
}

func TestConnectionRepo_Accept_ByRequesterIsForbidden(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice7", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob7", "Y")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	// Accept-your-own-request, the headline bug: alice sent it, so only bob
	// may move it to accepted.
	if _, err := repo.Accept(ctx, pending.ID, alice); !errors.Is(err, ErrConnectionForbidden) {
		t.Fatalf("Accept by requester returned %v, want ErrConnectionForbidden", err)
	}
	if state := connectionStateByID(t, ctx, pending.ID); state != "pending" {
		t.Errorf("state after refused Accept = %q, want %q", state, "pending")
	}
}

func TestConnectionRepo_Accept_AlreadyAcceptedReturnsErrConnectionNotPending(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice8", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob8", "Y")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if _, err := repo.Accept(ctx, pending.ID, bob); err != nil {
		t.Fatalf("first Accept returned error: %v", err)
	}
	if _, err := repo.Accept(ctx, pending.ID, bob); !errors.Is(err, ErrConnectionNotPending) {
		t.Fatalf("second Accept returned %v, want ErrConnectionNotPending", err)
	}
}

func TestConnectionRepo_Accept_ByThirdPartyReturnsErrNotFound(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice9", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob9", "Y")
	carol := newConnectionAttendeeFixture(t, ctx, "Carol9", "Z")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	// Not 403: telling a stranger "forbidden" would confirm that the id is
	// a real connection.
	if _, err := repo.Accept(ctx, pending.ID, carol); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Accept by third party returned %v, want ErrNotFound", err)
	}
	if state := connectionStateByID(t, ctx, pending.ID); state != "pending" {
		t.Errorf("state after third-party Accept = %q, want %q", state, "pending")
	}
}

func TestConnectionRepo_Accept_UnknownIDReturnsErrNotFound(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice10", "X")

	if _, err := repo.Accept(ctx, newUUID(), alice); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Accept of an unknown id returned %v, want ErrNotFound", err)
	}
}

func TestConnectionRepo_Delete_ByRequesterWithdrawsAndAllowsReconnect(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice11", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob11", "Y")
	cleanupConnection(t, alice, bob)

	first, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if err := repo.Delete(ctx, first.ID, alice); err != nil {
		t.Fatalf("Delete by requester returned error: %v", err)
	}
	if n := countConnectionRows(t, ctx, alice, bob); n != 0 {
		t.Fatalf("row count after withdraw = %d, want 0", n)
	}

	// Deleting rather than storing a 'declined' state is what makes this
	// possible: a stored declined row would conflict on the pair unique
	// index and silently no-op every future request between the two.
	again, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request after withdraw returned error: %v", err)
	}
	if again.ID == first.ID {
		t.Errorf("Request after withdraw reused id %q, want a new row", again.ID)
	}
	if again.State != models.ConnectionPending {
		t.Errorf("re-request state = %q, want %q", again.State, models.ConnectionPending)
	}
}

func TestConnectionRepo_Delete_ByAddresseeDeclinesRequest(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice12", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob12", "Y")
	cleanupConnection(t, alice, bob)

	pending, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if err := repo.Delete(ctx, pending.ID, bob); err != nil {
		t.Fatalf("Delete by addressee returned error: %v", err)
	}
	if n := countConnectionRows(t, ctx, alice, bob); n != 0 {
		t.Errorf("row count after decline = %d, want 0", n)
	}

	bobView, err := repo.Get(ctx, bob)
	if err != nil {
		t.Fatalf("Get(bob) returned error: %v", err)
	}
	if len(bobView.RequestsReceived) != 0 {
		t.Errorf("bob.RequestsReceived = %+v, want empty after declining", bobView.RequestsReceived)
	}
}

func TestConnectionRepo_Delete_AcceptedConnectionRemovableByEitherParty(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	// Run the same removal from both sides: an accepted connection is
	// symmetric, so neither party is privileged when it comes to ending it.
	for _, remover := range []string{"requester", "addressee"} {
		t.Run(remover, func(t *testing.T) {
			alice := newConnectionAttendeeFixture(t, ctx, "Alice13"+remover, "X")
			bob := newConnectionAttendeeFixture(t, ctx, "Bob13"+remover, "Y")
			cleanupConnection(t, alice, bob)

			conn, err := repo.Request(ctx, alice, bob)
			if err != nil {
				t.Fatalf("Request returned error: %v", err)
			}
			if _, err := repo.Accept(ctx, conn.ID, bob); err != nil {
				t.Fatalf("Accept returned error: %v", err)
			}

			caller := alice
			if remover == "addressee" {
				caller = bob
			}
			if err := repo.Delete(ctx, conn.ID, caller); err != nil {
				t.Fatalf("Delete by %s returned error: %v", remover, err)
			}
			if n := countConnectionRows(t, ctx, alice, bob); n != 0 {
				t.Errorf("row count after removal by %s = %d, want 0", remover, n)
			}
		})
	}
}

func TestConnectionRepo_Delete_ByThirdPartyReturnsErrNotFound(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice14", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob14", "Y")
	carol := newConnectionAttendeeFixture(t, ctx, "Carol14", "Z")
	cleanupConnection(t, alice, bob)

	conn, err := repo.Request(ctx, alice, bob)
	if err != nil {
		t.Fatalf("Request returned error: %v", err)
	}
	if err := repo.Delete(ctx, conn.ID, carol); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Delete by third party returned %v, want ErrNotFound", err)
	}
	if n := countConnectionRows(t, ctx, alice, bob); n != 1 {
		t.Errorf("row count after third-party Delete = %d, want the row still there", n)
	}
}

func TestConnectionRepo_Get_NoConnectionsReturnsEmptyNotNil(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	solo := newConnectionAttendeeFixture(t, ctx, "Solo", "Nobody")

	view, err := repo.Get(ctx, solo)
	if err != nil {
		t.Fatalf("Get returned error: %v", err)
	}
	if view.RequestsSent == nil || view.RequestsReceived == nil || view.Connections == nil {
		t.Errorf("expected empty (non-nil) slices, got %+v", view)
	}
}

func TestConnectionRepo_Schema_RefusesSelfAndMirrorRows(t *testing.T) {
	ctx := context.Background()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice15", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob15", "Y")
	cleanupConnection(t, alice, bob)
	cleanupConnection(t, alice, alice)

	// The Go guards above are convenience, not the guarantee. Assert the
	// constraints directly, so a future refactor that drops a check in Go
	// still cannot write a self row or a mirror row.
	if _, err := testDB.Exec(ctx,
		"INSERT INTO user_connection (requester_id, addressee_id) VALUES ($1, $1)", alice,
	); err == nil {
		t.Error("inserting a self row succeeded, want user_connection_no_self to refuse it")
	}

	if _, err := testDB.Exec(ctx,
		"INSERT INTO user_connection (requester_id, addressee_id) VALUES ($1, $2)", alice, bob,
	); err != nil {
		t.Fatalf("inserting the first row of the pair failed: %v", err)
	}
	if _, err := testDB.Exec(ctx,
		"INSERT INTO user_connection (requester_id, addressee_id) VALUES ($1, $2)", bob, alice,
	); err == nil {
		t.Error("inserting the mirror row succeeded, want user_connection_pair_unique to refuse it")
	}
}
