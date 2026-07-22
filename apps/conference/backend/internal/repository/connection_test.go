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
	"fmt"
	"testing"

	"wso2-coin-backend/internal/models"
)

func newConnectionAttendeeFixture(t *testing.T, ctx context.Context, firstName, lastName string) (idpUUID string) {
	t.Helper()
	repo := NewAttendeeProfileRepo(testDB, attendeeProfileTestKey)
	idpUUID = newUUID()
	err := repo.Insert(ctx, models.AttendeeInsert{
		Email:     fmt.Sprintf("%s-%s@example.com", firstName, newUUID()),
		FirstName: firstName,
		LastName:  lastName,
		MemberID:  "m-" + newUUID(),
	}, idpUUID)
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

func cleanupConnection(t *testing.T, a, b string) {
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(),
			"DELETE FROM user_connection WHERE (initiator_id = $1 AND recipient_id = $2) OR (initiator_id = $2 AND recipient_id = $1)",
			a, b)
	})
}

func TestConnectionRepo_Upsert_PendingRequestAppearsAsSentAndReceived(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice", "Sender")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob", "Receiver")
	cleanupConnection(t, alice, bob)

	if err := repo.Upsert(ctx, alice, bob, models.ConnectionPending); err != nil {
		t.Fatalf("Upsert returned error: %v", err)
	}

	aliceView, err := repo.Get(ctx, alice)
	if err != nil {
		t.Fatalf("Get(alice) returned error: %v", err)
	}
	if len(aliceView.RequestsSent) != 1 || aliceView.RequestsSent[0].UserID != bob {
		t.Errorf("alice.RequestsSent = %+v, want exactly bob", aliceView.RequestsSent)
	}
	if len(aliceView.RequestsReceived) != 0 {
		t.Errorf("alice.RequestsReceived = %+v, want empty", aliceView.RequestsReceived)
	}
	if aliceView.RequestsSent[0].Name != "Bob Receiver" {
		t.Errorf("alice.RequestsSent[0].Name = %q, want %q", aliceView.RequestsSent[0].Name, "Bob Receiver")
	}

	bobView, err := repo.Get(ctx, bob)
	if err != nil {
		t.Fatalf("Get(bob) returned error: %v", err)
	}
	if len(bobView.RequestsReceived) != 1 || bobView.RequestsReceived[0].UserID != alice {
		t.Errorf("bob.RequestsReceived = %+v, want exactly alice", bobView.RequestsReceived)
	}
	if len(bobView.RequestsSent) != 0 {
		t.Errorf("bob.RequestsSent = %+v, want empty", bobView.RequestsSent)
	}
}

func TestConnectionRepo_Upsert_AcceptedAppearsAsConnectionForBoth(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice2", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob2", "Y")
	cleanupConnection(t, alice, bob)

	if err := repo.Upsert(ctx, alice, bob, models.ConnectionPending); err != nil {
		t.Fatalf("Upsert(pending) returned error: %v", err)
	}
	if err := repo.Upsert(ctx, bob, alice, models.ConnectionAccepted); err != nil {
		t.Fatalf("Upsert(accepted) returned error: %v", err)
	}

	aliceView, err := repo.Get(ctx, alice)
	if err != nil {
		t.Fatalf("Get(alice) returned error: %v", err)
	}
	if len(aliceView.Connections) != 1 || aliceView.Connections[0].UserID != bob {
		t.Errorf("alice.Connections = %+v, want exactly bob", aliceView.Connections)
	}
	if len(aliceView.RequestsSent) != 0 {
		t.Errorf("alice.RequestsSent = %+v, want empty once accepted", aliceView.RequestsSent)
	}

	bobView, err := repo.Get(ctx, bob)
	if err != nil {
		t.Fatalf("Get(bob) returned error: %v", err)
	}
	if len(bobView.Connections) != 1 || bobView.Connections[0].UserID != alice {
		t.Errorf("bob.Connections = %+v, want exactly alice", bobView.Connections)
	}
}

func TestConnectionRepo_Upsert_ReverseDirectionUpdatesSameRowNotADuplicate(t *testing.T) {
	ctx := context.Background()
	repo := newConnectionRepo()

	alice := newConnectionAttendeeFixture(t, ctx, "Alice3", "X")
	bob := newConnectionAttendeeFixture(t, ctx, "Bob3", "Y")
	cleanupConnection(t, alice, bob)

	if err := repo.Upsert(ctx, alice, bob, models.ConnectionPending); err != nil {
		t.Fatalf("Upsert(alice->bob pending) returned error: %v", err)
	}
	// Upsert from the reverse direction (bob, alice) must update the same
	// row, not insert a second (bob, alice) row alongside (alice, bob).
	if err := repo.Upsert(ctx, bob, alice, models.ConnectionAccepted); err != nil {
		t.Fatalf("Upsert(bob->alice accepted) returned error: %v", err)
	}

	var count int
	err := testDB.QueryRow(ctx,
		"SELECT COUNT(*) FROM user_connection WHERE (initiator_id = $1 AND recipient_id = $2) OR (initiator_id = $2 AND recipient_id = $1)",
		alice, bob,
	).Scan(&count)
	if err != nil {
		t.Fatalf("failed to count rows: %v", err)
	}
	if count != 1 {
		t.Fatalf("row count = %d, want exactly 1 (no duplicate A/B + B/A pair)", count)
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
