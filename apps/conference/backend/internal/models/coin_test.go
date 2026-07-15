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

// TestEventTypeString tests the String() method for EventType enum
func TestEventTypeString(t *testing.T) {
	tests := []struct {
		name     string
		et       EventType
		expected string
	}{
		{
			name:     "EventTypeSession",
			et:       EventTypeSession,
			expected: "SESSION",
		},
		{
			name:     "EventTypeO2Bar",
			et:       EventTypeO2Bar,
			expected: "O2BAR",
		},
		{
			name:     "EventTypeGeneral",
			et:       EventTypeGeneral,
			expected: "GENERAL",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.et.String(); got != tt.expected {
				t.Errorf("EventType.String() = %v, want %v", got, tt.expected)
			}
		})
	}
}

// TestTransactionStatusString tests the String() method for TransactionStatus enum
func TestTransactionStatusString(t *testing.T) {
	tests := []struct {
		name     string
		ts       TransactionStatus
		expected string
	}{
		{
			name:     "TransactionStatusPending",
			ts:       TransactionStatusPending,
			expected: "PENDING",
		},
		{
			name:     "TransactionStatusProcessing",
			ts:       TransactionStatusProcessing,
			expected: "PROCESSING",
		},
		{
			name:     "TransactionStatusTransferred",
			ts:       TransactionStatusTransferred,
			expected: "TRANSFERRED",
		},
		{
			name:     "TransactionStatusFailed",
			ts:       TransactionStatusFailed,
			expected: "FAILED",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.ts.String(); got != tt.expected {
				t.Errorf("TransactionStatus.String() = %v, want %v", got, tt.expected)
			}
		})
	}
}

// TestQrScanRequestMarshal tests marshaling QrScanRequest to JSON
func TestQrScanRequestMarshal(t *testing.T) {
	req := QrScanRequest{
		QrID: "qr-123-abc",
	}

	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("Failed to marshal QrScanRequest: %v", err)
	}

	var result map[string]interface{}
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	if val, ok := result["qrId"]; !ok || val != "qr-123-abc" {
		t.Errorf("Expected qrId field in JSON, got %v", result)
	}
}

// TestQrScanRequestUnmarshal tests unmarshaling JSON into QrScanRequest
func TestQrScanRequestUnmarshal(t *testing.T) {
	jsonData := []byte(`{"qrId": "qr-456-def"}`)

	var req QrScanRequest
	err := json.Unmarshal(jsonData, &req)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	if req.QrID != "qr-456-def" {
		t.Errorf("Expected QrID = qr-456-def, got %v", req.QrID)
	}
}

// TestQrCodeInfoSessionType tests QrCodeInfo with EventType SESSION
func TestQrCodeInfoSessionType(t *testing.T) {
	info := QrCodeInfo{
		EventType: EventTypeSession,
		SessionID: "session-123",
	}

	data, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("Failed to marshal QrCodeInfo: %v", err)
	}

	var result map[string]interface{}
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify required fields
	if et, ok := result["eventType"]; !ok || et != "SESSION" {
		t.Errorf("Expected eventType=SESSION, got %v", result)
	}

	if sid, ok := result["sessionId"]; !ok || sid != "session-123" {
		t.Errorf("Expected sessionId field, got %v", result)
	}

	// Verify omitted fields are not present
	if _, ok := result["email"]; ok {
		t.Error("Expected email field to be omitted due to omitempty")
	}

	if _, ok := result["eventTypeName"]; ok {
		t.Error("Expected eventTypeName field to be omitted due to omitempty")
	}
}

// TestQrCodeInfoO2BarType tests QrCodeInfo with EventType O2BAR
func TestQrCodeInfoO2BarType(t *testing.T) {
	info := QrCodeInfo{
		EventType: EventTypeO2Bar,
		Email:     "user@example.com",
	}

	data, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("Failed to marshal QrCodeInfo: %v", err)
	}

	var result map[string]interface{}
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify required fields
	if et, ok := result["eventType"]; !ok || et != "O2BAR" {
		t.Errorf("Expected eventType=O2BAR, got %v", result)
	}

	if email, ok := result["email"]; !ok || email != "user@example.com" {
		t.Errorf("Expected email field, got %v", result)
	}

	// Verify omitted fields are not present
	if _, ok := result["sessionId"]; ok {
		t.Error("Expected sessionId field to be omitted due to omitempty")
	}

	if _, ok := result["eventTypeName"]; ok {
		t.Error("Expected eventTypeName field to be omitted due to omitempty")
	}
}

// TestQrCodeInfoGeneralType tests QrCodeInfo with EventType GENERAL
func TestQrCodeInfoGeneralType(t *testing.T) {
	info := QrCodeInfo{
		EventType:     EventTypeGeneral,
		EventTypeName: "Workshop",
	}

	data, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("Failed to marshal QrCodeInfo: %v", err)
	}

	var result map[string]interface{}
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify required fields
	if et, ok := result["eventType"]; !ok || et != "GENERAL" {
		t.Errorf("Expected eventType=GENERAL, got %v", result)
	}

	if name, ok := result["eventTypeName"]; !ok || name != "Workshop" {
		t.Errorf("Expected eventTypeName field, got %v", result)
	}

	// Verify omitted fields are not present
	if _, ok := result["sessionId"]; ok {
		t.Error("Expected sessionId field to be omitted due to omitempty")
	}

	if _, ok := result["email"]; ok {
		t.Error("Expected email field to be omitted due to omitempty")
	}
}

// TestConferenceQrCodeMarshalUnmarshal tests marshaling and unmarshaling ConferenceQrCode
func TestConferenceQrCodeMarshalUnmarshal(t *testing.T) {
	original := ConferenceQrCode{
		QrID: "qr-789",
		Info: QrCodeInfo{
			EventType: EventTypeSession,
			SessionID: "session-456",
		},
		Description: "Test QR Code",
		Coins:       100.50,
		CreatedBy:   "admin@example.com",
		CreatedOn:   "2026-01-15T10:30:00Z",
	}

	// Marshal to JSON
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("Failed to marshal ConferenceQrCode: %v", err)
	}

	// Unmarshal back
	var result ConferenceQrCode
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify all fields
	if result.QrID != original.QrID {
		t.Errorf("QrID mismatch: expected %v, got %v", original.QrID, result.QrID)
	}

	if result.Info.EventType != original.Info.EventType {
		t.Errorf("EventType mismatch: expected %v, got %v", original.Info.EventType, result.Info.EventType)
	}

	if result.Info.SessionID != original.Info.SessionID {
		t.Errorf("SessionID mismatch: expected %v, got %v", original.Info.SessionID, result.Info.SessionID)
	}

	if result.Coins != original.Coins {
		t.Errorf("Coins mismatch: expected %v, got %v", original.Coins, result.Coins)
	}

	if result.CreatedBy != original.CreatedBy {
		t.Errorf("CreatedBy mismatch: expected %v, got %v", original.CreatedBy, result.CreatedBy)
	}

	if result.CreatedOn != original.CreatedOn {
		t.Errorf("CreatedOn mismatch: expected %v, got %v", original.CreatedOn, result.CreatedOn)
	}
}

// TestWalletMarshalUnmarshal tests marshaling and unmarshaling Wallet
func TestWalletMarshalUnmarshal(t *testing.T) {
	wallet := Wallet{
		WalletAddress: "0x742d35Cc6634C0532925a3b844Bc2e7595f0bEb",
	}

	data, err := json.Marshal(wallet)
	if err != nil {
		t.Fatalf("Failed to marshal Wallet: %v", err)
	}

	var result Wallet
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	if result.WalletAddress != wallet.WalletAddress {
		t.Errorf("WalletAddress mismatch: expected %v, got %v", wallet.WalletAddress, result.WalletAddress)
	}
}

// TestCoinAllocationMarshalUnmarshal tests marshaling and unmarshaling CoinAllocation
func TestCoinAllocationMarshalUnmarshal(t *testing.T) {
	now := time.Now()
	eventData := json.RawMessage(`{"key":"value"}`)

	allocation := CoinAllocation{
		ID:                "alloc-123",
		QrID:              "qr-789",
		EventType:         EventTypeSession,
		UserUUID:          "user-uuid-123",
		WalletAddress:     "0x742d35Cc6634C0532925a3b844Bc2e7595f0bEb",
		CoinsAllocated:    50.25,
		TransactionStatus: TransactionStatusPending,
		EventData:         eventData,
		CreatedAt:         now,
		UpdatedAt:         now,
	}

	data, err := json.Marshal(allocation)
	if err != nil {
		t.Fatalf("Failed to marshal CoinAllocation: %v", err)
	}

	var result CoinAllocation
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify all fields
	if result.ID != allocation.ID {
		t.Errorf("ID mismatch: expected %v, got %v", allocation.ID, result.ID)
	}

	if result.QrID != allocation.QrID {
		t.Errorf("QrID mismatch: expected %v, got %v", allocation.QrID, result.QrID)
	}

	if result.EventType != allocation.EventType {
		t.Errorf("EventType mismatch: expected %v, got %v", allocation.EventType, result.EventType)
	}

	if result.UserUUID != allocation.UserUUID {
		t.Errorf("UserUUID mismatch: expected %v, got %v", allocation.UserUUID, result.UserUUID)
	}

	if result.WalletAddress != allocation.WalletAddress {
		t.Errorf("WalletAddress mismatch: expected %v, got %v", allocation.WalletAddress, result.WalletAddress)
	}

	if result.CoinsAllocated != allocation.CoinsAllocated {
		t.Errorf("CoinsAllocated mismatch: expected %v, got %v", allocation.CoinsAllocated, result.CoinsAllocated)
	}

	if result.TransactionStatus != allocation.TransactionStatus {
		t.Errorf("TransactionStatus mismatch: expected %v, got %v", allocation.TransactionStatus, result.TransactionStatus)
	}

	// Verify EventType and TransactionStatus are correct typed constants
	if result.TransactionStatus != TransactionStatusPending {
		t.Errorf("TransactionStatus not the correct typed constant: expected %v, got %v", TransactionStatusPending, result.TransactionStatus)
	}

	if result.EventType != EventTypeSession {
		t.Errorf("EventType not the correct typed constant: expected %v, got %v", EventTypeSession, result.EventType)
	}
}

// TestCoinAllocationHistoryMarshalUnmarshal tests marshaling and unmarshaling CoinAllocationHistory
func TestCoinAllocationHistoryMarshalUnmarshal(t *testing.T) {
	now := time.Now()

	history := CoinAllocationHistory{
		CoinsAllocated:    75.50,
		CreatedOn:         now,
		TransactionStatus: TransactionStatusTransferred,
		EventTypeName:     "Conference",
	}

	data, err := json.Marshal(history)
	if err != nil {
		t.Fatalf("Failed to marshal CoinAllocationHistory: %v", err)
	}

	var result CoinAllocationHistory
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify all fields
	if result.CoinsAllocated != history.CoinsAllocated {
		t.Errorf("CoinsAllocated mismatch: expected %v, got %v", history.CoinsAllocated, result.CoinsAllocated)
	}

	if result.TransactionStatus != history.TransactionStatus {
		t.Errorf("TransactionStatus mismatch: expected %v, got %v", history.TransactionStatus, result.TransactionStatus)
	}

	if result.EventTypeName != history.EventTypeName {
		t.Errorf("EventTypeName mismatch: expected %v, got %v", history.EventTypeName, result.EventTypeName)
	}

	// Verify TransactionStatus is the correct typed constant
	if result.TransactionStatus != TransactionStatusTransferred {
		t.Errorf("TransactionStatus not the correct typed constant: expected %v, got %v", TransactionStatusTransferred, result.TransactionStatus)
	}
}

// TestCoinAllocationSummaryMarshalUnmarshal tests marshaling and unmarshaling CoinAllocationSummary
func TestCoinAllocationSummaryMarshalUnmarshal(t *testing.T) {
	summary := CoinAllocationSummary{
		TotalPending:     150.75,
		TotalTransferred: 500.25,
	}

	data, err := json.Marshal(summary)
	if err != nil {
		t.Fatalf("Failed to marshal CoinAllocationSummary: %v", err)
	}

	var result CoinAllocationSummary
	err = json.Unmarshal(data, &result)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify all fields
	if result.TotalPending != summary.TotalPending {
		t.Errorf("TotalPending mismatch: expected %v, got %v", summary.TotalPending, result.TotalPending)
	}

	if result.TotalTransferred != summary.TotalTransferred {
		t.Errorf("TotalTransferred mismatch: expected %v, got %v", summary.TotalTransferred, result.TotalTransferred)
	}
}

// TestConferenceQrCodeUnmarshalFromJSON tests unmarshaling a complete JSON blob into ConferenceQrCode
func TestConferenceQrCodeUnmarshalFromJSON(t *testing.T) {
	jsonData := []byte(`{
		"qrId": "qr-test-123",
		"info": {
			"eventType": "O2BAR",
			"email": "test@example.com"
		},
		"description": "Test Description",
		"coins": 200.75,
		"createdBy": "creator@example.com",
		"createdOn": "2026-01-20T15:45:30Z"
	}`)

	var qrCode ConferenceQrCode
	err := json.Unmarshal(jsonData, &qrCode)
	if err != nil {
		t.Fatalf("Failed to unmarshal JSON: %v", err)
	}

	// Verify all fields populated correctly
	if qrCode.QrID != "qr-test-123" {
		t.Errorf("QrID mismatch: expected qr-test-123, got %v", qrCode.QrID)
	}

	if qrCode.Info.EventType != EventTypeO2Bar {
		t.Errorf("EventType mismatch: expected O2BAR, got %v", qrCode.Info.EventType)
	}

	if qrCode.Info.Email != "test@example.com" {
		t.Errorf("Email mismatch: expected test@example.com, got %v", qrCode.Info.Email)
	}

	if qrCode.Description != "Test Description" {
		t.Errorf("Description mismatch: expected Test Description, got %v", qrCode.Description)
	}

	if qrCode.Coins != 200.75 {
		t.Errorf("Coins mismatch: expected 200.75, got %v", qrCode.Coins)
	}

	if qrCode.CreatedBy != "creator@example.com" {
		t.Errorf("CreatedBy mismatch: expected creator@example.com, got %v", qrCode.CreatedBy)
	}

	if qrCode.CreatedOn != "2026-01-20T15:45:30Z" {
		t.Errorf("CreatedOn mismatch: expected 2026-01-20T15:45:30Z, got %v", qrCode.CreatedOn)
	}
}
