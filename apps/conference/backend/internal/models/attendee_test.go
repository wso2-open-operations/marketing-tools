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

package models

import (
	"encoding/json"
	"testing"
	"time"
)

func TestAttendee_JSONShape(t *testing.T) {
	a := Attendee{
		ID:         "attendee-1",
		Email:      "ada@example.com",
		IDPUUID:    "idp-1",
		MemberID:   "00vVM00000abcdef",
		Title:      "Engineer",
		Company:    "WSO2",
		Country:    "Sri Lanka",
		FirstName:  "Ada",
		LastName:   "Lovelace",
		IsPartner:  true,
		ProfileURL: "https://example.com/ada.webp",
		QRUri:      "WCabcdef",
		CreatedAt:  time.Now(),
		UpdatedAt:  time.Now(),
	}

	b, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{
		"id", "email", "uuid", "memberId", "title", "company", "country",
		"firstName", "lastName", "isPartner", "profileUrl", "qrUri", "createdOn", "updatedOn",
	} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
	if _, ok := got["email"]; !ok {
		t.Errorf("expected %q key present (unlike Speaker, Attendee keeps email)", "email")
	}
}

func TestAttendee_OptionalFieldsOmittedWhenEmpty(t *testing.T) {
	a := Attendee{ID: "attendee-1", Email: "ada@example.com"}

	b, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"uuid", "memberId", "title", "company", "country", "firstName", "lastName", "profileUrl", "createdBy", "updatedBy"} {
		if _, ok := got[key]; ok {
			t.Errorf("expected %q to be omitted when empty, got %v", key, got)
		}
	}
}

func TestAttendeeSearchResult_JSONShape(t *testing.T) {
	r := AttendeeSearchResult{
		Attendees:    []Attendee{{ID: "attendee-1", Email: "ada@example.com"}},
		StartIndex:   1,
		ItemsPerPage: 10,
		TotalResults: 1,
	}

	b, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"attendees", "startIndex", "itemsPerPage", "totalResults"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
}

func TestProfile_JSONShape(t *testing.T) {
	p := Profile{Username: "ada", Email: "ada@example.com", ImageURL: "https://example.com/ada.webp", QRUri: "idp-1", IsPartner: false}

	b, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}

	for _, key := range []string{"username", "email", "imageUrl", "qrUri", "isPartner"} {
		if _, ok := got[key]; !ok {
			t.Errorf("expected JSON key %q, got keys %v", key, got)
		}
	}
}

func TestAttendeePatch_UnmarshalDistinguishesAbsentFromEmpty(t *testing.T) {
	var patch AttendeePatch
	if err := json.Unmarshal([]byte(`{"title":"New Title"}`), &patch); err != nil {
		t.Fatalf("Unmarshal returned error: %v", err)
	}
	if patch.Title == nil || *patch.Title != "New Title" {
		t.Errorf("Title = %v, want pointer to %q", patch.Title, "New Title")
	}
	if patch.Company != nil {
		t.Errorf("Company = %v, want nil (absent from payload)", patch.Company)
	}
}
