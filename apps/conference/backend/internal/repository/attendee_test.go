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
	"testing"

	"wso2-coin-backend/internal/crypto"
)

// testPIIKey is a throwaway 32-byte AES key. Fixtures are encrypted with it and
// read back with it, so nothing here depends on the deployment's real key.
var testPIIKey = []byte("0123456789abcdef0123456789abcdef")

// anySessionID returns an existing sessions.id, which attendee_registration's
// FK requires. The table is populated by the agenda-organizer app; this test
// only needs a row to point at.
func anySessionID(t *testing.T, ctx context.Context) string {
	t.Helper()
	var id string
	if err := testDB.QueryRow(ctx, "SELECT id FROM sessions LIMIT 1").Scan(&id); err != nil {
		t.Skipf("no sessions row to hang an attendee_registration fixture off: %v", err)
	}
	return id
}

func seedRegistration(t *testing.T, ctx context.Context, attendeeID, sessionID string) {
	t.Helper()
	_, err := testDB.Exec(ctx,
		`INSERT INTO attendee_registration (attendee_id, session_id, updated_by)
		 VALUES ($1, $2, 'repo-test')`,
		attendeeID, sessionID,
	)
	if err != nil {
		t.Fatalf("failed to insert attendee_registration fixture: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(),
			"DELETE FROM attendee_registration WHERE attendee_id = $1", attendeeID)
	})
}

// attendee_registration.attendee_id stores the attendee's email *encrypted*
// with the PII key, not in plaintext, so IsRegistered has to decrypt to compare.
func TestAttendeeRepo_IsRegistered_MatchesEncryptedEmail(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeRepo(testDB, testPIIKey)

	const registeredEmail = "qa.registered@example.com"
	const unregisteredEmail = "qa.nobody@example.com"

	ct, err := crypto.EncryptPII(registeredEmail, testPIIKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	seedRegistration(t, ctx, ct, anySessionID(t, ctx))

	ok, err := repo.IsRegistered(ctx, registeredEmail)
	if err != nil {
		t.Fatalf("IsRegistered(%q) returned error: %v", registeredEmail, err)
	}
	if !ok {
		t.Errorf("IsRegistered(%q) = false, want true", registeredEmail)
	}

	ok, err = repo.IsRegistered(ctx, unregisteredEmail)
	if err != nil {
		t.Fatalf("IsRegistered(%q) returned error: %v", unregisteredEmail, err)
	}
	if ok {
		t.Errorf("IsRegistered(%q) = true, want false", unregisteredEmail)
	}
}

// Rows encrypted under a different key must not error the whole scan -- one
// unreadable registration cannot be allowed to kill coin earning for everyone.
func TestAttendeeRepo_IsRegistered_SkipsUndecryptableRows(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeRepo(testDB, testPIIKey)

	sessionID := anySessionID(t, ctx)

	otherKey := []byte("ffffffffffffffff0123456789abcdef")
	junk, err := crypto.EncryptPII("qa.otherkey@example.com", otherKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	seedRegistration(t, ctx, junk, sessionID)

	const registeredEmail = "qa.readable@example.com"
	ct, err := crypto.EncryptPII(registeredEmail, testPIIKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	seedRegistration(t, ctx, ct, sessionID)

	ok, err := repo.IsRegistered(ctx, registeredEmail)
	if err != nil {
		t.Fatalf("IsRegistered returned error: %v", err)
	}
	if !ok {
		t.Error("IsRegistered = false; an undecryptable neighbour row must be skipped, not fatal")
	}
}

// Case and surrounding whitespace in the JWT email must not decide whether an
// attendee earns coins.
func TestAttendeeRepo_IsRegistered_IsCaseInsensitive(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeRepo(testDB, testPIIKey)

	ct, err := crypto.EncryptPII("QA.Mixed@Example.com", testPIIKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	seedRegistration(t, ctx, ct, anySessionID(t, ctx))

	ok, err := repo.IsRegistered(ctx, "  qa.mixed@example.COM  ")
	if err != nil {
		t.Fatalf("IsRegistered returned error: %v", err)
	}
	if !ok {
		t.Error("IsRegistered = false for the same address in different case, want true")
	}
}

func TestAttendeeRepo_IsRegistered_EmptyEmailIsNotRegistered(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeRepo(testDB, testPIIKey)

	ok, err := repo.IsRegistered(ctx, "   ")
	if err != nil {
		t.Fatalf("IsRegistered returned error: %v", err)
	}
	if ok {
		t.Error("IsRegistered(\"   \") = true, want false")
	}
}
