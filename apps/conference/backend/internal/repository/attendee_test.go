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

var attendeeTestKey = mustDecodeTestKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

func TestAttendeeRepo_IsRegistered(t *testing.T) {
	ctx := context.Background()
	repo := NewAttendeeRepo(testDB, attendeeTestKey)

	const registeredEmail = "attendee@example.com"
	const unregisteredEmail = "nobody@example.com"

	fixture := newSessionFixture(t, ctx, "2026-09-01", 540)
	sessionID := fixture.insertUnscheduledSession(t, ctx)

	encrypted, err := crypto.EncryptPII(registeredEmail, attendeeTestKey)
	if err != nil {
		t.Fatalf("failed to encrypt fixture email: %v", err)
	}
	_, err = testDB.Exec(ctx,
		"INSERT INTO attendee_registration (attendee_id, session_id, updated_by) VALUES ($1, $2, $3)",
		encrypted, sessionID, "tdd-test",
	)
	if err != nil {
		t.Fatalf("failed to insert fixture row: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(),
			"DELETE FROM attendee_registration WHERE session_id = $1", sessionID)
	})

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
