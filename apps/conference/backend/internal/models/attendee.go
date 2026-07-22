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

import "time"

// Attendee represents a conference attendee's profile, as returned by
// GET /attendees/me, POST /attendees/search and PATCH /attendees.
// Title/Company/Country/FirstName/LastName are encrypted at rest (see
// internal/crypto); the repository layer decrypts them before this struct is
// populated, same as Speaker.
type Attendee struct {
	ID         string    `json:"id"`
	Email      string    `json:"email"`
	IDPUUID    string    `json:"uuid,omitempty"`
	MemberID   string    `json:"memberId,omitempty"`
	Title      string    `json:"title,omitempty"`
	Company    string    `json:"company,omitempty"`
	Country    string    `json:"country,omitempty"`
	FirstName  string    `json:"firstName,omitempty"`
	LastName   string    `json:"lastName,omitempty"`
	IsPartner  bool      `json:"isPartner"`
	ProfileURL string    `json:"profileUrl,omitempty"`
	QRUri      string    `json:"qrUri"`
	CreatedBy  string    `json:"createdBy,omitempty"`
	UpdatedBy  string    `json:"updatedBy,omitempty"`
	CreatedAt  time.Time `json:"createdOn"`
	UpdatedAt  time.Time `json:"updatedOn"`
}

// AttendeeInsert is the payload for POST /attendees. IDPUUID is deliberately
// not part of this payload: it's taken from the caller's authenticated JWT
// sub, never trusted from the request body (see .claude/PLAN.md).
type AttendeeInsert struct {
	Email      string `json:"email"`
	Title      string `json:"title"`
	Company    string `json:"company"`
	Country    string `json:"country"`
	FirstName  string `json:"firstName"`
	LastName   string `json:"lastName"`
	MemberID   string `json:"memberId"`
	IsPartner  bool   `json:"isPartner"`
	ProfileURL string `json:"profileUrl,omitempty"`
}

// AttendeePatch is the partial-update payload for PATCH /attendees. Nil
// fields are left unchanged.
type AttendeePatch struct {
	Title      *string `json:"title,omitempty"`
	Company    *string `json:"company,omitempty"`
	Country    *string `json:"country,omitempty"`
	FirstName  *string `json:"firstName,omitempty"`
	LastName   *string `json:"lastName,omitempty"`
	ProfileURL *string `json:"profileUrl,omitempty"`
}

// AttendeeSearchFilter narrows POST /attendees/search: an optional single
// uuid to look up, plus pagination.
type AttendeeSearchFilter struct {
	UUID         string
	StartIndex   int
	ItemsPerPage int
}

// AttendeeSearchResult is the paginated response for POST /attendees/search.
type AttendeeSearchResult struct {
	Attendees    []Attendee `json:"attendees"`
	StartIndex   int        `json:"startIndex"`
	ItemsPerPage int        `json:"itemsPerPage"`
	TotalResults int        `json:"totalResults"`
}

// Profile is the response shape for GET /user-profile.
type Profile struct {
	Username  string `json:"username"`
	Email     string `json:"email"`
	ImageURL  string `json:"imageUrl"`
	QRUri     string `json:"qrUri"`
	IsPartner bool   `json:"isPartner"`
}
