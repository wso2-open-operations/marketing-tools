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
// MemberID/QRUri are only populated on the caller's own row: qrUri is the
// check-in credential, so POST /attendees/search blanks both (audit P2).
// Title/Company/Country/FirstName/LastName are encrypted at rest (see
// internal/crypto); the repository layer decrypts them before this struct is
// populated, same as Speaker.
type Attendee struct {
	ID string `json:"id"`
	// Email is omitted rather than empty when withheld. It is present on the
	// caller's own record (GET /attendees/me, POST /attendees) and absent from
	// attendee search results, which no longer read the column at all: a
	// directory lookup handed out every attendee's address to anyone
	// authenticated, so no connection state could gate it.
	Email      string    `json:"email,omitempty"`
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

// AttendeeInsert is the payload for POST /attendees. Neither IDPUUID nor
// Email is part of this payload: both are identity, both come from the
// caller's authenticated JWT (sub and email), never from the request body.
// A body `email` is accepted by the decoder and ignored.
//
// FirstName/LastName are required: an empty POST used to create an
// email=” row against the caller's UNIQUE idp_uuid, after which every
// later POST 500'd and GET /attendees/me 404'd forever (audit A4).
type AttendeeInsert struct {
	Title      string `json:"title"`
	Company    string `json:"company"`
	Country    string `json:"country"`
	FirstName  string `json:"firstName" binding:"required"`
	LastName   string `json:"lastName" binding:"required"`
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
// uuid to look up, an optional case-insensitive text query, and cursor
// pagination.
//
// Query matches (case-insensitive substring) against the attendee's name
// ("firstName lastName"), company, or title. All three are AES-GCM encrypted
// at rest, so the match runs in Go after decryption -- an SQL ILIKE over the
// ciphertext would be meaningless (the same constraint speakers hit in Phase
// B). Cursor is the opaque keyset position; Limit is the page size (0 means
// "use the repository default").
type AttendeeSearchFilter struct {
	UUID   string
	Query  string
	Cursor string
	Limit  int
}

// AttendeeSearchResult is the paginated response for POST /attendees/search.
// Items is always a non-nil array. Page.NextCursor is empty when there are no
// further pages. total is deliberately omitted: an accurate count over the
// text query would require decrypting every attendee row (see PageInfo).
type AttendeeSearchResult struct {
	Items []Attendee `json:"items"`
	Page  PageInfo   `json:"page"`
}

// PageInfo is the pagination envelope shared by cursor-paginated list
// responses. NextCursor is an opaque token to pass back as the next request's
// cursor; an empty string means the last page has been reached. total is not
// included: attendee search filters over encrypted columns in Go, so an exact
// filtered total isn't cheaply computable, and the plan marks total optional.
type PageInfo struct {
	NextCursor string `json:"nextCursor"`
}

// Profile is the response shape for GET /user-profile.
type Profile struct {
	Username  string `json:"username"`
	Email     string `json:"email"`
	ImageURL  string `json:"imageUrl"`
	QRUri     string `json:"qrUri"`
	IsPartner bool   `json:"isPartner"`
}
