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

package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

// --- fakes ---

type fakeAttendeeRepo struct {
	isRegistered bool
	err          error
}

func (f *fakeAttendeeRepo) IsRegistered(ctx context.Context, email string) (bool, error) {
	return f.isRegistered, f.err
}

type fakeAllocationRepo struct {
	existsResult bool
	existsErr    error
	insertErr    error
	insertedRows []models.CoinAllocation

	updateStatusErr   error
	updateStatusCalls []updateStatusCall
}

type updateStatusCall struct {
	qrID, userUUID string
	status         models.TransactionStatus
}

func (f *fakeAllocationRepo) Exists(ctx context.Context, qrID, userUUID string) (bool, error) {
	return f.existsResult, f.existsErr
}

func (f *fakeAllocationRepo) Insert(ctx context.Context, alloc models.CoinAllocation) (models.CoinAllocation, error) {
	if f.insertErr != nil {
		return models.CoinAllocation{}, f.insertErr
	}
	f.insertedRows = append(f.insertedRows, alloc)
	alloc.ID = "generated-id"
	return alloc, nil
}

func (f *fakeAllocationRepo) UpdateStatus(ctx context.Context, qrID, userUUID string, status models.TransactionStatus) error {
	f.updateStatusCalls = append(f.updateStatusCalls, updateStatusCall{qrID, userUUID, status})
	return f.updateStatusErr
}

func (f *fakeAllocationRepo) History(ctx context.Context, userUUID string) ([]models.CoinAllocationHistory, error) {
	return nil, nil
}

func (f *fakeAllocationRepo) Summary(ctx context.Context, userUUID string) (models.CoinAllocationSummary, error) {
	return models.CoinAllocationSummary{}, nil
}

type fakeSessionRepo struct {
	start, end time.Time
	err        error
}

func (f *fakeSessionRepo) GetTimeWindow(ctx context.Context, sessionID string) (time.Time, time.Time, error) {
	return f.start, f.end, f.err
}

type fakeQRPortalClient struct {
	qrCode *models.ConferenceQrCode
	err    error
}

func (f *fakeQRPortalClient) GetQRCode(ctx context.Context, qrID string) (*models.ConferenceQrCode, error) {
	return f.qrCode, f.err
}

type fakeWalletClient struct {
	wallet *models.Wallet
	err    error
}

func (f *fakeWalletClient) GetPrimaryWallet(ctx context.Context, email string) (*models.Wallet, error) {
	return f.wallet, f.err
}

// --- test harness ---

type harness struct {
	attendees   *fakeAttendeeRepo
	allocations *fakeAllocationRepo
	sessions    *fakeSessionRepo
	qrPortal    *fakeQRPortalClient
	wallets     *fakeWalletClient
	svc         *CoinService
}

func newHarness(cfg ScanConfig, now time.Time) *harness {
	h := &harness{
		attendees:   &fakeAttendeeRepo{isRegistered: true},
		allocations: &fakeAllocationRepo{},
		sessions:    &fakeSessionRepo{},
		qrPortal: &fakeQRPortalClient{
			qrCode: &models.ConferenceQrCode{
				QrID:  "qr-1",
				Info:  models.QrCodeInfo{EventType: models.EventTypeGeneral, EventTypeName: "Booth Visit"},
				Coins: 10,
			},
		},
		wallets: &fakeWalletClient{wallet: &models.Wallet{WalletAddress: "0xabc"}},
	}
	h.svc = NewCoinService(h.attendees, h.allocations, h.sessions, h.qrPortal, h.wallets, cfg)
	h.svc.Now = func() time.Time { return now }
	return h
}

const testUserID = "user-uuid-1"
const testEmail = "attendee@example.com"

func defaultConfig() ScanConfig {
	return ScanConfig{
		ExcludeEmployeeCoinAllocation: true,
		EnableQrValidations:           true,
		SessionEndTimeOffsetMinutes:   15,
	}
}

func TestScanQR_NotRegisteredAttendee(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	h.attendees.isRegistered = false

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, ErrNotRegisteredAttendee) {
		t.Fatalf("expected ErrNotRegisteredAttendee, got %v", err)
	}
}

func TestScanQR_AttendeeRepoError_PropagatesGenericError(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	wantErr := errors.New("db down")
	h.attendees.err = wantErr

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, wantErr) {
		t.Fatalf("expected wrapped db error, got %v", err)
	}
	if errors.Is(err, ErrNotRegisteredAttendee) {
		t.Fatal("generic errors must not be classified as ErrNotRegisteredAttendee")
	}
}

func TestScanQR_WSO2EmployeeExcluded(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())

	err := h.svc.ScanQR(context.Background(), testUserID, "someone@wso2.com", "qr-1")

	if !errors.Is(err, ErrWSO2EmployeeNotEligible) {
		t.Fatalf("expected ErrWSO2EmployeeNotEligible, got %v", err)
	}
}

func TestScanQR_WSO2EmployeeExclusionCaseInsensitive(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())

	err := h.svc.ScanQR(context.Background(), testUserID, "someone@WSO2.COM", "qr-1")

	if !errors.Is(err, ErrWSO2EmployeeNotEligible) {
		t.Fatalf("expected ErrWSO2EmployeeNotEligible for mixed-case domain, got %v", err)
	}
}

func TestScanQR_WSO2EmployeeAllowedWhenFlagDisabled(t *testing.T) {
	cfg := defaultConfig()
	cfg.ExcludeEmployeeCoinAllocation = false
	h := newHarness(cfg, time.Now())

	err := h.svc.ScanQR(context.Background(), testUserID, "someone@wso2.com", "qr-1")

	if err != nil {
		t.Fatalf("expected success with exclusion disabled, got %v", err)
	}
}

func TestScanQR_AlreadyScanned(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	h.allocations.existsResult = true

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, ErrQRAlreadyScanned) {
		t.Fatalf("expected ErrQRAlreadyScanned, got %v", err)
	}
}

func TestScanQR_QRPortalError(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	wantErr := errors.New("qr portal down")
	h.qrPortal.err = wantErr
	h.qrPortal.qrCode = nil

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, wantErr) {
		t.Fatalf("expected wrapped qr portal error, got %v", err)
	}
}

func TestScanQR_WalletNotFound(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	h.wallets.wallet = nil

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, ErrWalletNotFound) {
		t.Fatalf("expected ErrWalletNotFound, got %v", err)
	}
}

func TestScanQR_WalletLookupError(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	wantErr := errors.New("wallet service down")
	h.wallets.err = wantErr

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, wantErr) {
		t.Fatalf("expected wrapped wallet error, got %v", err)
	}
}

func sessionQR() *models.ConferenceQrCode {
	return &models.ConferenceQrCode{
		QrID:  "qr-session",
		Info:  models.QrCodeInfo{EventType: models.EventTypeSession, SessionID: "session-1"},
		Coins: 25,
	}
}

func TestScanQR_SessionNotStarted(t *testing.T) {
	now := time.Date(2026, 5, 21, 8, 0, 0, 0, time.UTC)
	h := newHarness(defaultConfig(), now)
	h.qrPortal.qrCode = sessionQR()
	h.sessions.start = time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	h.sessions.end = time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if !errors.Is(err, ErrSessionNotStarted) {
		t.Fatalf("expected ErrSessionNotStarted, got %v", err)
	}
}

func TestScanQR_QRScanWindowExpired(t *testing.T) {
	cfg := defaultConfig()
	cfg.SessionEndTimeOffsetMinutes = 15
	// session ends 9:30, +15min grace = 9:45 cutoff; now is 10:00 -> expired.
	now := time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC)
	h := newHarness(cfg, now)
	h.qrPortal.qrCode = sessionQR()
	h.sessions.start = time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	h.sessions.end = time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if !errors.Is(err, ErrQRScanWindowExpired) {
		t.Fatalf("expected ErrQRScanWindowExpired, got %v", err)
	}
}

func TestScanQR_WithinSessionWindow_Succeeds(t *testing.T) {
	// session 9:00-9:30, grace 15min -> valid until 9:45; now 9:20 -> within window.
	now := time.Date(2026, 5, 21, 9, 20, 0, 0, time.UTC)
	h := newHarness(defaultConfig(), now)
	h.qrPortal.qrCode = sessionQR()
	h.sessions.start = time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	h.sessions.end = time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if err != nil {
		t.Fatalf("expected success within session window, got %v", err)
	}
}

func TestScanQR_WithinGracePeriodAfterSessionEnd_Succeeds(t *testing.T) {
	// session 9:00-9:30, grace 15min -> valid until 9:45; now 9:40 -> within grace.
	now := time.Date(2026, 5, 21, 9, 40, 0, 0, time.UTC)
	h := newHarness(defaultConfig(), now)
	h.qrPortal.qrCode = sessionQR()
	h.sessions.start = time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	h.sessions.end = time.Date(2026, 5, 21, 9, 30, 0, 0, time.UTC)

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if err != nil {
		t.Fatalf("expected success within grace period, got %v", err)
	}
}

func TestScanQR_SessionValidationSkippedWhenFlagDisabled(t *testing.T) {
	cfg := defaultConfig()
	cfg.EnableQrValidations = false
	now := time.Date(2026, 5, 21, 8, 0, 0, 0, time.UTC) // would be "not started" if validated
	h := newHarness(cfg, now)
	h.qrPortal.qrCode = sessionQR()
	h.sessions.err = errors.New("should never be called")

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if err != nil {
		t.Fatalf("expected success with validations disabled, got %v", err)
	}
}

func TestScanQR_O2BarQR_NoSessionValidation(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	h.qrPortal.qrCode = &models.ConferenceQrCode{
		QrID:  "qr-o2bar",
		Info:  models.QrCodeInfo{EventType: models.EventTypeO2Bar, Email: "bar@example.com"},
		Coins: 5,
	}
	h.sessions.err = errors.New("should never be called for O2BAR")

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-o2bar")

	if err != nil {
		t.Fatalf("expected success, O2BAR should skip session validation, got %v", err)
	}
}

func TestScanQR_SessionLookupError_Propagates(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	h.qrPortal.qrCode = sessionQR()
	h.sessions.err = repository.ErrNotFound

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-session")

	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("expected wrapped repository.ErrNotFound, got %v", err)
	}
}

func TestScanQR_Success_InsertsPendingThenForcesFailed(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")
	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}

	if len(h.allocations.insertedRows) != 1 {
		t.Fatalf("expected exactly 1 insert, got %d", len(h.allocations.insertedRows))
	}
	inserted := h.allocations.insertedRows[0]
	if inserted.QrID != "qr-1" {
		t.Errorf("QrID = %q, want qr-1", inserted.QrID)
	}
	if inserted.UserUUID != testUserID {
		t.Errorf("UserUUID = %q, want %q", inserted.UserUUID, testUserID)
	}
	if inserted.WalletAddress != "0xabc" {
		t.Errorf("WalletAddress = %q, want 0xabc", inserted.WalletAddress)
	}
	if inserted.CoinsAllocated != 10 {
		t.Errorf("CoinsAllocated = %v, want 10", inserted.CoinsAllocated)
	}
	if inserted.TransactionStatus != models.TransactionStatusPending {
		t.Errorf("TransactionStatus = %v, want PENDING at insert time", inserted.TransactionStatus)
	}
	if inserted.EventType != models.EventTypeGeneral {
		t.Errorf("EventType = %v, want GENERAL", inserted.EventType)
	}

	// Mirrors production: the real transfer is disabled, so every allocation
	// is immediately force-marked FAILED after the initial PENDING insert.
	if len(h.allocations.updateStatusCalls) != 1 {
		t.Fatalf("expected exactly 1 UpdateStatus call, got %d", len(h.allocations.updateStatusCalls))
	}
	call := h.allocations.updateStatusCalls[0]
	if call.status != models.TransactionStatusFailed {
		t.Errorf("UpdateStatus status = %v, want FAILED", call.status)
	}
	if call.qrID != "qr-1" || call.userUUID != testUserID {
		t.Errorf("UpdateStatus called with (%q, %q), want (qr-1, %q)", call.qrID, call.userUUID, testUserID)
	}
}

func TestScanQR_Success_EventDataShapePerEventType(t *testing.T) {
	tests := []struct {
		name    string
		qrCode  *models.ConferenceQrCode
		wantKey string
		wantVal string
	}{
		{"session", &models.ConferenceQrCode{QrID: "q1", Info: models.QrCodeInfo{EventType: models.EventTypeSession, SessionID: "sess-1"}, Coins: 1}, "sessionId", "sess-1"},
		{"o2bar", &models.ConferenceQrCode{QrID: "q2", Info: models.QrCodeInfo{EventType: models.EventTypeO2Bar, Email: "bar@x.com"}, Coins: 1}, "o2BarEmail", "bar@x.com"},
		{"general", &models.ConferenceQrCode{QrID: "q3", Info: models.QrCodeInfo{EventType: models.EventTypeGeneral, EventTypeName: "Raffle"}, Coins: 1}, "eventTypeName", "Raffle"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := defaultConfig()
			cfg.EnableQrValidations = false // avoid needing session fixtures for the session case
			h := newHarness(cfg, time.Now())
			h.qrPortal.qrCode = tt.qrCode

			if err := h.svc.ScanQR(context.Background(), testUserID, testEmail, tt.qrCode.QrID); err != nil {
				t.Fatalf("expected success, got %v", err)
			}

			if len(h.allocations.insertedRows) != 1 {
				t.Fatalf("expected 1 insert, got %d", len(h.allocations.insertedRows))
			}
			eventData := string(h.allocations.insertedRows[0].EventData)
			wantSubstr := `"` + tt.wantKey + `":"` + tt.wantVal + `"`
			if !strings.Contains(eventData, wantSubstr) {
				t.Errorf("eventData = %s, want it to contain %s", eventData, wantSubstr)
			}
		})
	}
}

func TestScanQR_InsertError_Propagates(t *testing.T) {
	h := newHarness(defaultConfig(), time.Now())
	wantErr := errors.New("insert failed")
	h.allocations.insertErr = wantErr

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if !errors.Is(err, wantErr) {
		t.Fatalf("expected wrapped insert error, got %v", err)
	}
}

func TestScanQR_UpdateStatusError_DoesNotFailTheOverallScan(t *testing.T) {
	// Mirrors production: the status flip happens after the "success" response
	// would already have been sent, so its failure must never surface to the caller.
	h := newHarness(defaultConfig(), time.Now())
	h.allocations.updateStatusErr = errors.New("update failed")

	err := h.svc.ScanQR(context.Background(), testUserID, testEmail, "qr-1")

	if err != nil {
		t.Fatalf("expected success even though UpdateStatus failed internally, got %v", err)
	}
}
