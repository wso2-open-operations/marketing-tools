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

// ConnectionStatus mirrors the old Ballerina CONNECTION_PENDING/ACCEPTED/
// REJECTED constants.
type ConnectionStatus int

const (
	ConnectionRejected ConnectionStatus = -1
	ConnectionPending  ConnectionStatus = 0
	ConnectionAccepted ConnectionStatus = 1
)

// IsValid reports whether s is one of the defined connection statuses.
func (s ConnectionStatus) IsValid() bool {
	switch s {
	case ConnectionRejected, ConnectionPending, ConnectionAccepted:
		return true
	default:
		return false
	}
}

// String is the JSON-facing label for a connection status, so responses carry
// the state explicitly instead of encoding it only via which array an item
// sits in.
func (s ConnectionStatus) String() string {
	switch s {
	case ConnectionRejected:
		return "rejected"
	case ConnectionPending:
		return "pending"
	case ConnectionAccepted:
		return "accepted"
	default:
		return "unknown"
	}
}

// Connection is one stored user_connection row. The direction matters: only
// RecipientID may accept a pending request, so callers need the stored
// direction, not just the pair.
type Connection struct {
	InitiatorID string
	RecipientID string
	Status      ConnectionStatus
}

// ConnectionUserInfo describes the other party in a connection, enriched
// from that user's attendee profile. Status is the explicit connection state
// ("pending"/"accepted"), always present so the client reads it directly
// rather than inferring it from which array the item sits in.
type ConnectionUserInfo struct {
	UserID     string `json:"userId"`
	Name       string `json:"name"`
	Email      string `json:"email"`
	Status     string `json:"status"`
	ProfileURL string `json:"profileUrl,omitempty"`
	Title      string `json:"title,omitempty"`
	Company    string `json:"company,omitempty"`
	Country    string `json:"country,omitempty"`
}

// UserConnectionsInfo is the response shape for GET /users/me/connections.
type UserConnectionsInfo struct {
	RequestsSent     []ConnectionUserInfo `json:"requestsSent"`
	RequestsReceived []ConnectionUserInfo `json:"requestsReceived"`
	Connections      []ConnectionUserInfo `json:"connections"`
}

// UserConnectionRequest is the payload for POST /users/me/connections.
// userId is required: an empty target used to be written as a row against
// the empty string.
type UserConnectionRequest struct {
	UserID string           `json:"userId" binding:"required"`
	Status ConnectionStatus `json:"status"`
}
