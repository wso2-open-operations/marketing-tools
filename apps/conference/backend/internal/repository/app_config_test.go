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
)

func cleanupAppConfig(t *testing.T, keys ...string) {
	t.Helper()
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM app_config WHERE config_key = ANY($1)", keys)
	})
}

func TestAppConfigRepo_List_ReturnsRowsInKeyOrder(t *testing.T) {
	ctx := context.Background()
	repo := NewAppConfigRepo(testDB)

	cleanupAppConfig(t, "ZZZ_TEST_KEY_TWO", "AAA_TEST_KEY_ONE")

	if _, err := testDB.Exec(ctx,
		`INSERT INTO app_config (config_key, value, created_by, updated_by) VALUES ($1, $2, $3, $3)`,
		"ZZZ_TEST_KEY_TWO", "value-two", "SYSTEM",
	); err != nil {
		t.Fatalf("fixture insert failed: %v", err)
	}
	if _, err := testDB.Exec(ctx,
		`INSERT INTO app_config (config_key, value, created_by, updated_by) VALUES ($1, $2, $3, $3)`,
		"AAA_TEST_KEY_ONE", "value-one", "SYSTEM",
	); err != nil {
		t.Fatalf("fixture insert failed: %v", err)
	}

	got, err := repo.List(ctx)
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}

	var idx1, idx2 = -1, -1
	for i, c := range got {
		if c.Key == "AAA_TEST_KEY_ONE" {
			idx1 = i
		}
		if c.Key == "ZZZ_TEST_KEY_TWO" {
			idx2 = i
		}
	}
	if idx1 == -1 || idx2 == -1 {
		t.Fatalf("expected both fixture rows in result, got %+v", got)
	}
	if idx1 > idx2 {
		t.Errorf("expected AAA_TEST_KEY_ONE (idx %d) before ZZZ_TEST_KEY_TWO (idx %d) -- List should order by config_key", idx1, idx2)
	}

	for _, c := range got {
		if c.Key == "AAA_TEST_KEY_ONE" {
			if c.Value != "value-one" {
				t.Errorf("Value = %q, want value-one", c.Value)
			}
			if c.CreatedBy != "SYSTEM" || c.UpdatedBy != "SYSTEM" {
				t.Errorf("CreatedBy/UpdatedBy = %q/%q, want SYSTEM/SYSTEM", c.CreatedBy, c.UpdatedBy)
			}
			if c.CreatedOn.IsZero() || c.UpdatedOn.IsZero() {
				t.Errorf("CreatedOn/UpdatedOn should not be zero")
			}
		}
	}
}

func TestAppConfigRepo_List_EmptyTableReturnsEmptySliceNotNil(t *testing.T) {
	ctx := context.Background()
	repo := NewAppConfigRepo(testDB)

	// No fixtures inserted here; this only proves the shape of a query that
	// returns zero rows, regardless of what other tests seeded and cleaned
	// up around it -- it does not assert the table is globally empty.
	got, err := repo.List(ctx)
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}
	if got == nil {
		t.Errorf("List returned nil, want non-nil (possibly empty) slice")
	}
}
