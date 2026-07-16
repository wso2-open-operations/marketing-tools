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
	"time"
)

// EventType is an enum for different event types
type EventType string

const (
	EventTypeSession EventType = "SESSION"
	EventTypeO2Bar   EventType = "O2BAR"
	EventTypeGeneral EventType = "GENERAL"
)

// String returns the string representation of EventType
func (e EventType) String() string {
	return string(e)
}

// TransactionStatus is an enum for transaction statuses
type TransactionStatus string

const (
	TransactionStatusPending     TransactionStatus = "PENDING"
	TransactionStatusProcessing  TransactionStatus = "PROCESSING"
	TransactionStatusTransferred TransactionStatus = "TRANSFERRED"
	TransactionStatusFailed      TransactionStatus = "FAILED"
)

// String returns the string representation of TransactionStatus
func (t TransactionStatus) String() string {
	return string(t)
}

// QrScanRequest represents the request body for POST /qr/scan
type QrScanRequest struct {
	QrID string `json:"qrId" binding:"required"`
}

// QrCodeInfo contains information about a QR code based on its event type
type QrCodeInfo struct {
	EventType     EventType `json:"eventType"`
	SessionID     string    `json:"sessionId,omitempty"`
	Email         string    `json:"email,omitempty"`
	EventTypeName string    `json:"eventTypeName,omitempty"`
}

// ConferenceQrCode represents a QR code fetched from the external QR Portal service
type ConferenceQrCode struct {
	QrID        string     `json:"qrId"`
	Info        QrCodeInfo `json:"info"`
	Description string     `json:"description,omitempty"`
	Coins       float64    `json:"coins"`
	CreatedBy   string     `json:"createdBy"`
	CreatedOn   string     `json:"createdOn"`
}

// Wallet represents a user's primary wallet
type Wallet struct {
	WalletAddress string `json:"walletAddress"`
}

// CoinAllocation represents a row in the coin_allocation DB table
type CoinAllocation struct {
	ID                string            `json:"id"`
	QrID              string            `json:"qrId"`
	EventType         EventType         `json:"eventType"`
	UserUUID          string            `json:"userUuid"`
	WalletAddress     string            `json:"walletAddress"`
	CoinsAllocated    float64           `json:"coinsAllocated"`
	TransactionStatus TransactionStatus `json:"transactionStatus"`
	EventData         json.RawMessage   `json:"eventData"`
	CreatedAt         time.Time         `json:"createdAt"`
	UpdatedAt         time.Time         `json:"updatedAt"`
}

// CoinAllocationHistory represents one row of GET /qr/history response
type CoinAllocationHistory struct {
	CoinsAllocated    float64           `json:"coinsAllocated"`
	CreatedOn         time.Time         `json:"createdOn"`
	TransactionStatus TransactionStatus `json:"transactionStatus"`
	EventTypeName     string            `json:"eventTypeName"`
}

// CoinAllocationSummary represents the response of GET /qr/summary
type CoinAllocationSummary struct {
	TotalPending     float64 `json:"totalPending"`
	TotalTransferred float64 `json:"totalTransferred"`
}
