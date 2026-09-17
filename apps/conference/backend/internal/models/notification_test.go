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
	"strings"
	"testing"
)

func TestUserNotificationRequest_Validate(t *testing.T) {
	tests := []struct {
		name        string
		title       string
		description string
		want        string
	}{
		{"valid", "Keynote starting", "Hall A, in 10 minutes", ""},
		{"empty title", "", "body", "title is required"},
		{"whitespace-only title", "   \t\n ", "body", "title is required"},
		{"empty description is allowed", "title", "", ""},

		// ASCII: one byte per character, so the byte boundary and the character
		// boundary coincide. These pin the exact limit and one byte past it.
		{"title at byte limit", strings.Repeat("a", NotificationTitleMaxBytes), "", ""},
		{"title one byte over limit", strings.Repeat("a", NotificationTitleMaxBytes+1), "", "title exceeds the maximum length"},
		{"description at byte limit", "title", strings.Repeat("a", NotificationBodyMaxBytes), ""},
		{"description one byte over limit", "title", strings.Repeat("a", NotificationBodyMaxBytes+1), "description exceeds the maximum length"},

		// Multi-byte input must be counted in BYTES, matching the downstream
		// wso2con handler's len() check and FCM's 4 KB byte budget. Each of
		// these Sinhala/emoji cases sits at or under the *rune* limit and so
		// used to be accepted here -- and was then rejected downstream, turning
		// a clean 400 into a 500 for the admin.
		{"multi-byte title within the rune limit but over the byte limit", strings.Repeat("ම", NotificationTitleMaxBytes), "", "title exceeds the maximum length"},
		{"emoji title within the rune limit but over the byte limit", strings.Repeat("🎉", NotificationTitleMaxBytes), "", "title exceeds the maximum length"},
		{"multi-byte description within the rune limit but over the byte limit", "title", strings.Repeat("ම", NotificationBodyMaxBytes), "description exceeds the maximum length"},

		// The byte boundary itself, reached with multi-byte runes: "ම" is 3
		// bytes and "🎉" is 4, so these land exactly on the cap (66*3 = 198,
		// plus two ASCII bytes = 200) and exactly one byte past it.
		{"multi-byte title exactly at the byte limit", strings.Repeat("ම", 66) + "aa", "", ""},
		{"multi-byte title one byte over the byte limit", strings.Repeat("ම", 66) + "aaa", "", "title exceeds the maximum length"},
		{"emoji title exactly at the byte limit", strings.Repeat("🎉", 50), "", ""},
		{"emoji title one byte over the byte limit", strings.Repeat("🎉", 50) + "a", "", "title exceeds the maximum length"},
		{"multi-byte description exactly at the byte limit", "title", strings.Repeat("ම", 333) + "a", ""},
		{"multi-byte description one byte over the byte limit", "title", strings.Repeat("ම", 333) + "aa", "description exceeds the maximum length"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := UserNotificationRequest{Title: tt.title, Description: tt.description}
			if got := req.Validate(); got != tt.want {
				t.Errorf("Validate() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestUserNotificationRequest_ValidateTrimsInPlace(t *testing.T) {
	req := UserNotificationRequest{Title: "  Keynote  ", Description: "\n Hall A \t"}

	if problem := req.Validate(); problem != "" {
		t.Fatalf("Validate() = %q, want no problem", problem)
	}
	if req.Title != "Keynote" {
		t.Errorf("Title = %q, want %q", req.Title, "Keynote")
	}
	if req.Description != "Hall A" {
		t.Errorf("Description = %q, want %q", req.Description, "Hall A")
	}
}

// Surrounding whitespace must not push an otherwise-valid title over the
// limit, since trimming happens before the length check.
func TestUserNotificationRequest_ValidateTrimsBeforeLengthCheck(t *testing.T) {
	req := UserNotificationRequest{Title: "  " + strings.Repeat("a", NotificationTitleMaxBytes) + "  "}

	if got := req.Validate(); got != "" {
		t.Errorf("Validate() = %q, want no problem", got)
	}
}
