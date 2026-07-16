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

// Package service implements the WSO2 Coin / O2C QR-scan business workflow.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// Sentinel errors mapped by the handler layer to specific HTTP status codes.
// Their messages match the ones the ported Ballerina service returned.
var (
	ErrNotRegisteredAttendee   = errors.New("You are not registered as an attendee for today's agenda.")
	ErrWSO2EmployeeNotEligible = errors.New("WSO2 employees are not eligible for coin rewards.")
	ErrQRAlreadyScanned        = errors.New("This QR code has already been scanned.")
	ErrWalletNotFound          = errors.New("Wallet not found. Please create a WSO2 Wallet to receive coins.")
	ErrSessionNotStarted       = errors.New("This session has not started yet. Please check the agenda and try again later.")
	ErrQRScanWindowExpired     = errors.New("This QR code is no longer valid.")
)

const wso2EmailSuffix = "@wso2.com"

// QRPortalClient resolves a scanned QR code's metadata from the external QR Portal service.
type QRPortalClient interface {
	GetQRCode(ctx context.Context, qrID string) (*models.ConferenceQrCode, error)
}

// WalletClient resolves a user's primary wallet from the external Wallet service.
type WalletClient interface {
	GetPrimaryWallet(ctx context.Context, email string) (*models.Wallet, error)
}

// ScanConfig holds the feature flags that govern the QR scan workflow.
type ScanConfig struct {
	ExcludeEmployeeCoinAllocation bool
	EnableQrValidations           bool
	SessionEndTimeOffsetMinutes   int
}

// CoinService orchestrates the QR scan -> coin allocation workflow.
type CoinService struct {
	attendees   repository.AttendeeRepository
	allocations repository.CoinAllocationRepository
	sessions    repository.SessionRepository
	qrPortal    QRPortalClient
	wallets     WalletClient
	cfg         ScanConfig

	// Now returns the current time; overridable in tests for deterministic
	// session time-window assertions.
	Now func() time.Time
}

// NewCoinService constructs a CoinService.
func NewCoinService(
	attendees repository.AttendeeRepository,
	allocations repository.CoinAllocationRepository,
	sessions repository.SessionRepository,
	qrPortal QRPortalClient,
	wallets WalletClient,
	cfg ScanConfig,
) *CoinService {
	return &CoinService{
		attendees:   attendees,
		allocations: allocations,
		sessions:    sessions,
		qrPortal:    qrPortal,
		wallets:     wallets,
		cfg:         cfg,
		Now:         time.Now,
	}
}

// ScanQR runs the full QR-scan workflow for the given authenticated user and
// scanned QR code ID. A nil error means the scan was accepted (mirrors the
// ported Ballerina service, callers should respond 200 OK). Any returned
// error should be classified by the handler layer via errors.Is against the
// sentinel errors above (403/400 cases); anything else is an unexpected
// failure (500).
func (s *CoinService) ScanQR(ctx context.Context, userID, email, qrID string) error {
	registered, err := s.attendees.IsRegistered(ctx, email)
	if err != nil {
		return fmt.Errorf("service: checking attendee registration: %w", err)
	}
	if !registered {
		return ErrNotRegisteredAttendee
	}

	if s.cfg.ExcludeEmployeeCoinAllocation && strings.HasSuffix(strings.ToLower(email), wso2EmailSuffix) {
		return ErrWSO2EmployeeNotEligible
	}

	exists, err := s.allocations.Exists(ctx, qrID, userID)
	if err != nil {
		return fmt.Errorf("service: checking existing coin allocation: %w", err)
	}
	if exists {
		return ErrQRAlreadyScanned
	}

	qrCode, err := s.qrPortal.GetQRCode(ctx, qrID)
	if err != nil {
		return fmt.Errorf("service: fetching QR code: %w", err)
	}

	wallet, err := s.wallets.GetPrimaryWallet(ctx, email)
	if err != nil {
		return fmt.Errorf("service: fetching wallet: %w", err)
	}
	if wallet == nil {
		return ErrWalletNotFound
	}

	if s.cfg.EnableQrValidations && qrCode.Info.EventType == models.EventTypeSession {
		if err := s.validateSessionWindow(ctx, qrCode.Info.SessionID); err != nil {
			return err
		}
	}

	eventData, err := buildEventData(qrCode.Info)
	if err != nil {
		return fmt.Errorf("service: building event data: %w", err)
	}

	alloc := models.CoinAllocation{
		QrID:              qrID,
		EventType:         qrCode.Info.EventType,
		UserUUID:          userID,
		WalletAddress:     wallet.WalletAddress,
		CoinsAllocated:    qrCode.Coins,
		TransactionStatus: models.TransactionStatusPending,
		EventData:         eventData,
	}
	if _, err := s.allocations.Insert(ctx, alloc); err != nil {
		// A duplicate can slip past the earlier Exists check under a race
		// (two concurrent scans of the same QR by the same user); the DB's
		// unique constraint is the actual source of truth here.
		if errors.Is(err, repository.ErrDuplicateAllocation) {
			return ErrQRAlreadyScanned
		}
		return fmt.Errorf("service: inserting coin allocation: %w", err)
	}

	// Mirrors production: the real transfer call to the transaction/blockchain
	// service is disabled there (transfers are deferred to an out-of-band cron
	// job not present in this codebase); every allocation is force-marked
	// FAILED immediately after the PENDING insert instead. This happens after
	// the scan is already considered accepted, so its error is not surfaced.
	_ = s.allocations.UpdateStatus(ctx, qrID, userID, models.TransactionStatusFailed)

	return nil
}

func (s *CoinService) validateSessionWindow(ctx context.Context, sessionID string) error {
	start, end, err := s.sessions.GetTimeWindow(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("service: fetching session time window: %w", err)
	}

	now := s.Now()
	if now.Before(start) {
		return ErrSessionNotStarted
	}
	windowEnd := end.Add(time.Duration(s.cfg.SessionEndTimeOffsetMinutes) * time.Minute)
	if now.After(windowEnd) {
		return ErrQRScanWindowExpired
	}
	return nil
}

// buildEventData mirrors the ported service's event_data JSON shape per event type.
func buildEventData(info models.QrCodeInfo) (json.RawMessage, error) {
	var payload map[string]string
	switch info.EventType {
	case models.EventTypeSession:
		payload = map[string]string{"sessionId": info.SessionID}
	case models.EventTypeO2Bar:
		payload = map[string]string{"o2BarEmail": info.Email}
	case models.EventTypeGeneral:
		payload = map[string]string{"eventTypeName": info.EventTypeName}
	default:
		return nil, fmt.Errorf("unknown event type %q", info.EventType)
	}
	return json.Marshal(payload)
}
