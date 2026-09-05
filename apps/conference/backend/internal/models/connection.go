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

// ConnectionState is the stored state of one connection. It is deliberately
// not a request field: the route names the transition (request / accept /
// delete), so there is no value a caller can set to a state they are not
// allowed to reach. The old signed-int ConnectionStatus, which callers *did*
// set, is what made accept-your-own-request possible.
//
// There is no "declined": declining, withdrawing and removing all delete the
// row, so a refused pair returns to having no relationship at all. See
// migrations/014_user_connection_redesign.sql.
type ConnectionState string

const (
	ConnectionPending  ConnectionState = "pending"
	ConnectionAccepted ConnectionState = "accepted"
)

// IsValid reports whether s is one of the defined connection states. Nothing
// on the request path needs this -- states arrive from the database, never
// from a payload -- but it guards against a row written by an older build or
// by hand.
func (s ConnectionState) IsValid() bool {
	switch s {
	case ConnectionPending, ConnectionAccepted:
		return true
	default:
		return false
	}
}

// String is the JSON-facing label for a connection state.
func (s ConnectionState) String() string {
	if !s.IsValid() {
		return "unknown"
	}
	return string(s)
}

// Connection is one stored user_connection row -- one per unordered pair, not
// one per direction. RequesterID and AddresseeID still record who started it,
// because only the addressee may accept; the pair itself is unique regardless
// of which of the two is which.
type Connection struct {
	ID          string
	RequesterID string
	AddresseeID string
	State       ConnectionState
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Other returns the id of whichever party is not callerUUID, and whether
// callerUUID is a party to the connection at all. Handlers use it to decide
// whose profile to enrich the response with.
func (c Connection) Other(callerUUID string) (string, bool) {
	switch callerUUID {
	case c.RequesterID:
		return c.AddresseeID, true
	case c.AddresseeID:
		return c.RequesterID, true
	default:
		return "", false
	}
}

// ConnectionUserInfo describes the other party in a connection, enriched from
// that user's attendee profile.
//
// ConnectionID is the row's own id, and it is what the accept and delete
// routes address -- without it a client holding a GET response has no way to
// name the connection it wants to act on. Status is the explicit state,
// always present so the client reads it directly rather than inferring it
// from which array the item sits in.
type ConnectionUserInfo struct {
	ConnectionID string `json:"connectionId"`
	UserID       string `json:"userId"`
	Name         string `json:"name"`
	Email        string `json:"email"`
	Status       string `json:"status"`
	ProfileURL   string `json:"profileUrl,omitempty"`
	Title        string `json:"title,omitempty"`
	Company      string `json:"company,omitempty"`
	Country      string `json:"country,omitempty"`
}

// UserConnectionsInfo is the response shape for GET /users/me/connections.
type UserConnectionsInfo struct {
	RequestsSent     []ConnectionUserInfo `json:"requestsSent"`
	RequestsReceived []ConnectionUserInfo `json:"requestsReceived"`
	Connections      []ConnectionUserInfo `json:"connections"`
}

// ConnectionRequest is the payload for POST /users/me/connections. targetId is
// the only id ever taken from a body; the requester is always the JWT sub.
type ConnectionRequest struct {
	TargetID string `json:"targetId" binding:"required"`
}
