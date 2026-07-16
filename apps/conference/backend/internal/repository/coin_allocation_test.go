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
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"wso2-coin-backend/internal/models"
)

// newTestUserUUID returns a fresh, valid UUID string dedicated to a single
// test run so tests never collide over the same user_uuid.
func newTestUserUUID(t *testing.T) string {
	t.Helper()
	return newUUID()
}

func cleanupCoinAllocations(t *testing.T, userUUID string) {
	t.Helper()
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM coin_allocation WHERE user_uuid = $1", userUUID)
	})
}

func TestCoinAllocationRepo_ExistsAndInsert(t *testing.T) {
	ctx := context.Background()
	repo := NewCoinAllocationRepo(testDB)

	userUUID := newTestUserUUID(t)
	cleanupCoinAllocations(t, userUUID)

	qrID := newUUID()

	exists, err := repo.Exists(ctx, qrID, userUUID)
	if err != nil {
		t.Fatalf("Exists returned error: %v", err)
	}
	if exists {
		t.Fatalf("Exists = true before any insert, want false")
	}

	alloc := models.CoinAllocation{
		QrID:              qrID,
		EventType:         models.EventTypeGeneral,
		UserUUID:          userUUID,
		WalletAddress:     "0xabc123",
		CoinsAllocated:    10.5,
		TransactionStatus: models.TransactionStatusPending,
		EventData:         json.RawMessage(`{"eventTypeName":"Welcome Bonus"}`),
	}

	created, err := repo.Insert(ctx, alloc)
	if err != nil {
		t.Fatalf("Insert returned error: %v", err)
	}
	if created.ID == "" {
		t.Errorf("Insert did not populate ID")
	}
	if created.CreatedAt.IsZero() {
		t.Errorf("Insert did not populate CreatedAt")
	}
	if created.UpdatedAt.IsZero() {
		t.Errorf("Insert did not populate UpdatedAt")
	}
	if created.QrID != qrID {
		t.Errorf("QrID = %q, want %q", created.QrID, qrID)
	}
	if created.CoinsAllocated != 10.5 {
		t.Errorf("CoinsAllocated = %v, want 10.5", created.CoinsAllocated)
	}

	exists, err = repo.Exists(ctx, qrID, userUUID)
	if err != nil {
		t.Fatalf("Exists returned error: %v", err)
	}
	if !exists {
		t.Errorf("Exists = false after insert, want true")
	}
}

func TestCoinAllocationRepo_Insert_DuplicateReturnsErrDuplicateAllocation(t *testing.T) {
	// Simulates the race where two concurrent scans of the same QR by the
	// same user both pass an Exists check before either has inserted: the
	// second Insert must fail on the DB's (qr_id, user_uuid) unique
	// constraint, and the repository must translate that into
	// ErrDuplicateAllocation rather than a raw driver error.
	ctx := context.Background()
	repo := NewCoinAllocationRepo(testDB)

	userUUID := newTestUserUUID(t)
	cleanupCoinAllocations(t, userUUID)

	qrID := newUUID()
	alloc := models.CoinAllocation{
		QrID:              qrID,
		EventType:         models.EventTypeGeneral,
		UserUUID:          userUUID,
		WalletAddress:     "0xabc123",
		CoinsAllocated:    1,
		TransactionStatus: models.TransactionStatusPending,
		EventData:         json.RawMessage(`{}`),
	}

	if _, err := repo.Insert(ctx, alloc); err != nil {
		t.Fatalf("first Insert returned error: %v", err)
	}

	_, err := repo.Insert(ctx, alloc)
	if err == nil {
		t.Fatal("expected second Insert of the same (qr_id, user_uuid) to fail")
	}
	if !errors.Is(err, ErrDuplicateAllocation) {
		t.Errorf("expected ErrDuplicateAllocation, got %v", err)
	}
}

func TestCoinAllocationRepo_UpdateStatus(t *testing.T) {
	ctx := context.Background()
	repo := NewCoinAllocationRepo(testDB)

	userUUID := newTestUserUUID(t)
	cleanupCoinAllocations(t, userUUID)

	qrID := newUUID()
	alloc := models.CoinAllocation{
		QrID:              qrID,
		EventType:         models.EventTypeGeneral,
		UserUUID:          userUUID,
		WalletAddress:     "0xabc123",
		CoinsAllocated:    5,
		TransactionStatus: models.TransactionStatusPending,
		EventData:         json.RawMessage(`{}`),
	}
	if _, err := repo.Insert(ctx, alloc); err != nil {
		t.Fatalf("Insert returned error: %v", err)
	}

	if err := repo.UpdateStatus(ctx, qrID, userUUID, models.TransactionStatusTransferred); err != nil {
		t.Fatalf("UpdateStatus returned error: %v", err)
	}

	var status string
	var updatedAt time.Time
	err := testDB.QueryRow(ctx, "SELECT transaction_status, updated_at FROM coin_allocation WHERE qr_id = $1 AND user_uuid = $2", qrID, userUUID).Scan(&status, &updatedAt)
	if err != nil {
		t.Fatalf("failed to read back row: %v", err)
	}
	if status != string(models.TransactionStatusTransferred) {
		t.Errorf("transaction_status = %q, want %q", status, models.TransactionStatusTransferred)
	}
}

func TestCoinAllocationRepo_HistoryAndSummary(t *testing.T) {
	ctx := context.Background()
	repo := NewCoinAllocationRepo(testDB)

	userUUID := newTestUserUUID(t)
	cleanupCoinAllocations(t, userUUID)

	// Row 1: GENERAL, TRANSFERRED, 10 coins.
	qr1 := newUUID()
	insertHistoryRow(t, ctx, repo, qr1, userUUID, models.EventTypeGeneral, models.TransactionStatusTransferred, 10, "Welcome Bonus")
	time.Sleep(10 * time.Millisecond)

	// Row 2: GENERAL, FAILED (folds to PENDING), 5 coins.
	qr2 := newUUID()
	insertHistoryRow(t, ctx, repo, qr2, userUUID, models.EventTypeGeneral, models.TransactionStatusFailed, 5, "Booth Visit")
	time.Sleep(10 * time.Millisecond)

	// Row 3: GENERAL, PROCESSING (folds to PENDING), 3 coins.
	qr3 := newUUID()
	insertHistoryRow(t, ctx, repo, qr3, userUUID, models.EventTypeGeneral, models.TransactionStatusProcessing, 3, "Survey")
	time.Sleep(10 * time.Millisecond)

	// Row 4: GENERAL, PENDING, 2 coins.
	qr4 := newUUID()
	insertHistoryRow(t, ctx, repo, qr4, userUUID, models.EventTypeGeneral, models.TransactionStatusPending, 2, "Raffle")
	time.Sleep(10 * time.Millisecond)

	// Row 5: O2BAR, TRANSFERRED - must NOT appear in History or Summary (not GENERAL).
	qr5 := newUUID()
	insertHistoryRow(t, ctx, repo, qr5, userUUID, models.EventTypeO2Bar, models.TransactionStatusTransferred, 100, "Drink")

	history, err := repo.History(ctx, userUUID)
	if err != nil {
		t.Fatalf("History returned error: %v", err)
	}
	if len(history) != 4 {
		t.Fatalf("History returned %d rows, want 4: %+v", len(history), history)
	}

	// Ordered by created_at descending: row4, row3, row2, row1.
	wantOrder := []struct {
		coins  float64
		status models.TransactionStatus
		name   string
	}{
		{2, models.TransactionStatusPending, "Raffle"},
		{3, models.TransactionStatusPending, "Survey"},
		{5, models.TransactionStatusPending, "Booth Visit"},
		{10, models.TransactionStatusTransferred, "Welcome Bonus"},
	}
	for i, want := range wantOrder {
		got := history[i]
		if got.CoinsAllocated != want.coins {
			t.Errorf("history[%d].CoinsAllocated = %v, want %v", i, got.CoinsAllocated, want.coins)
		}
		if got.TransactionStatus != want.status {
			t.Errorf("history[%d].TransactionStatus = %v, want %v", i, got.TransactionStatus, want.status)
		}
		if got.EventTypeName != want.name {
			t.Errorf("history[%d].EventTypeName = %q, want %q", i, got.EventTypeName, want.name)
		}
	}

	summary, err := repo.Summary(ctx, userUUID)
	if err != nil {
		t.Fatalf("Summary returned error: %v", err)
	}
	// Pending pool: FAILED(5) + PROCESSING(3) + PENDING(2) = 10.
	if summary.TotalPending != 10 {
		t.Errorf("TotalPending = %v, want 10", summary.TotalPending)
	}
	// Transferred pool: 10 (O2BAR row excluded).
	if summary.TotalTransferred != 10 {
		t.Errorf("TotalTransferred = %v, want 10", summary.TotalTransferred)
	}
}

func insertHistoryRow(t *testing.T, ctx context.Context, repo *CoinAllocationRepo, qrID, userUUID string, eventType models.EventType, status models.TransactionStatus, coins float64, eventTypeName string) {
	t.Helper()
	eventData := json.RawMessage(fmt.Sprintf(`{"eventTypeName":%q}`, eventTypeName))
	alloc := models.CoinAllocation{
		QrID:              qrID,
		EventType:         eventType,
		UserUUID:          userUUID,
		WalletAddress:     "0xabc123",
		CoinsAllocated:    coins,
		TransactionStatus: status,
		EventData:         eventData,
	}
	if _, err := repo.Insert(ctx, alloc); err != nil {
		t.Fatalf("Insert fixture row returned error: %v", err)
	}
}
