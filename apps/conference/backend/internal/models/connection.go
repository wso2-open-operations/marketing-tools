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

// ConnectionUserInfo describes the other party in a connection, enriched
// from that user's attendee profile.
type ConnectionUserInfo struct {
	UserID     string `json:"userId"`
	Name       string `json:"name"`
	Email      string `json:"email"`
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
type UserConnectionRequest struct {
	UserID string           `json:"userId"`
	Status ConnectionStatus `json:"status"`
}
