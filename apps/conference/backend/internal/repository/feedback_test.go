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

	"wso2-coin-backend/internal/models"
)

func cleanupFeedback(t *testing.T, userUUID string) {
	t.Helper()
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM feedback WHERE user_uuid = $1", userUUID)
	})
}

func TestFeedbackRepo_Insert_SessionFeedbackStoresSessionIDNotEventID(t *testing.T) {
	ctx := context.Background()
	repo := NewFeedbackRepo(testDB)

	userUUID := newUUID()
	sessionID := newUUID()
	comment := "great talk"

	if err := repo.Insert(ctx, models.FeedbackInsert{
		UserUUID:     userUUID,
		FeedbackType: models.FeedbackSession,
		SessionID:    &sessionID,
		Rating:       5,
		Comment:      &comment,
	}); err != nil {
		t.Fatalf("Insert returned error: %v", err)
	}
	cleanupFeedback(t, userUUID)

	var gotType string
	var gotRating int
	var gotComment, gotSessionID *string
	var gotEventID *string
	err := testDB.QueryRow(ctx,
		"SELECT feedback_type, rating, comment, session_id, event_id FROM feedback WHERE user_uuid = $1",
		userUUID,
	).Scan(&gotType, &gotRating, &gotComment, &gotSessionID, &gotEventID)
	if err != nil {
		t.Fatalf("failed to query inserted row: %v", err)
	}

	if gotType != string(models.FeedbackSession) {
		t.Errorf("feedback_type = %q, want %q", gotType, models.FeedbackSession)
	}
	if gotRating != 5 {
		t.Errorf("rating = %d, want 5", gotRating)
	}
	if gotComment == nil || *gotComment != comment {
		t.Errorf("comment = %v, want %q", gotComment, comment)
	}
	if gotSessionID == nil || *gotSessionID != sessionID {
		t.Errorf("session_id = %v, want %q", gotSessionID, sessionID)
	}
	if gotEventID != nil {
		t.Errorf("event_id = %v, want nil for session feedback", gotEventID)
	}
}

func TestFeedbackRepo_Insert_EventFeedbackStoresEventIDNotSessionID(t *testing.T) {
	ctx := context.Background()
	repo := NewFeedbackRepo(testDB)

	userUUID := newUUID()
	eventID := newUUID()

	if err := repo.Insert(ctx, models.FeedbackInsert{
		UserUUID:     userUUID,
		FeedbackType: models.FeedbackEvent,
		EventID:      &eventID,
		Rating:       4,
	}); err != nil {
		t.Fatalf("Insert returned error: %v", err)
	}
	cleanupFeedback(t, userUUID)

	var gotType string
	var gotComment, gotSessionID, gotEventID *string
	err := testDB.QueryRow(ctx,
		"SELECT feedback_type, comment, session_id, event_id FROM feedback WHERE user_uuid = $1",
		userUUID,
	).Scan(&gotType, &gotComment, &gotSessionID, &gotEventID)
	if err != nil {
		t.Fatalf("failed to query inserted row: %v", err)
	}

	if gotType != string(models.FeedbackEvent) {
		t.Errorf("feedback_type = %q, want %q", gotType, models.FeedbackEvent)
	}
	if gotComment != nil {
		t.Errorf("comment = %v, want nil when not provided", gotComment)
	}
	if gotSessionID != nil {
		t.Errorf("session_id = %v, want nil for event feedback", gotSessionID)
	}
	if gotEventID == nil || *gotEventID != eventID {
		t.Errorf("event_id = %v, want %q", gotEventID, eventID)
	}
}
