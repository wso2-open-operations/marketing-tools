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

package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/service"
)

func init() {
	gin.SetMode(gin.TestMode)
}

type fakeScanner struct {
	err        error
	calledWith struct{ userID, email, qrID string }
}

func (f *fakeScanner) ScanQR(ctx context.Context, userID, email, qrID string) error {
	f.calledWith.userID = userID
	f.calledWith.email = email
	f.calledWith.qrID = qrID
	return f.err
}

type fakeReader struct {
	history    []models.CoinAllocationHistory
	historyErr error
	summary    models.CoinAllocationSummary
	summaryErr error
}

func (f *fakeReader) History(ctx context.Context, userUUID string) ([]models.CoinAllocationHistory, error) {
	return f.history, f.historyErr
}

func (f *fakeReader) Summary(ctx context.Context, userUUID string) (models.CoinAllocationSummary, error) {
	return f.summary, f.summaryErr
}

func newTestRouter(h *CoinHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			ctx := middleware.WithUserInfo(c.Request.Context(), user)
			c.Request = c.Request.WithContext(ctx)
		}
		c.Next()
	})
	r.POST("/qr/scan", h.Scan)
	r.GET("/qr/history", h.History)
	r.GET("/qr/summary", h.Summary)
	return r
}

var testUser = &middleware.UserInfo{Email: "attendee@example.com", UserID: "user-1"}

func doRequest(r *gin.Engine, method, path string, body any) *httptest.ResponseRecorder {
	var reqBody *bytes.Buffer
	if body != nil {
		b, _ := json.Marshal(body)
		reqBody = bytes.NewBuffer(b)
	} else {
		reqBody = bytes.NewBuffer(nil)
	}
	req := httptest.NewRequest(method, path, reqBody)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestScan_MissingUser_Returns401(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{})
	r := newTestRouter(h, nil)

	w := doRequest(r, http.MethodPost, "/qr/scan", models.QrScanRequest{QrID: "qr-1"})

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", w.Code, w.Body.String())
	}
}

func TestScan_InvalidBody_Returns400(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{})
	r := newTestRouter(h, testUser)

	req := httptest.NewRequest(http.MethodPost, "/qr/scan", bytes.NewBufferString(`{"qrId": 123}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
}

func TestScan_Success_Returns200(t *testing.T) {
	scanner := &fakeScanner{}
	h := NewCoinHandler(scanner, &fakeReader{})
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodPost, "/qr/scan", models.QrScanRequest{QrID: "qr-1"})

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	if scanner.calledWith.userID != testUser.UserID || scanner.calledWith.email != testUser.Email || scanner.calledWith.qrID != "qr-1" {
		t.Errorf("scanner called with unexpected args: %+v", scanner.calledWith)
	}
}

func TestScan_ErrorMapping(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantStatus int
	}{
		{"not registered", service.ErrNotRegisteredAttendee, http.StatusForbidden},
		{"wso2 employee", service.ErrWSO2EmployeeNotEligible, http.StatusForbidden},
		{"already scanned", service.ErrQRAlreadyScanned, http.StatusBadRequest},
		{"wallet not found", service.ErrWalletNotFound, http.StatusBadRequest},
		{"session not started", service.ErrSessionNotStarted, http.StatusBadRequest},
		{"window expired", service.ErrQRScanWindowExpired, http.StatusBadRequest},
		{"unexpected error", errors.New("boom"), http.StatusInternalServerError},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := NewCoinHandler(&fakeScanner{err: tt.err}, &fakeReader{})
			r := newTestRouter(h, testUser)

			w := doRequest(r, http.MethodPost, "/qr/scan", models.QrScanRequest{QrID: "qr-1"})

			if w.Code != tt.wantStatus {
				t.Fatalf("expected %d, got %d: %s", tt.wantStatus, w.Code, w.Body.String())
			}
			if tt.wantStatus != http.StatusInternalServerError {
				var body map[string]string
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
					t.Fatalf("decode response: %v", err)
				}
				if body["message"] != tt.err.Error() {
					t.Errorf("message = %q, want %q", body["message"], tt.err.Error())
				}
			}
		})
	}
}

func TestHistory_MissingUser_Returns401(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{})
	r := newTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/qr/history", nil)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestHistory_Success(t *testing.T) {
	reader := &fakeReader{history: []models.CoinAllocationHistory{
		{CoinsAllocated: 5, TransactionStatus: models.TransactionStatusPending, EventTypeName: "Raffle"},
	}}
	h := NewCoinHandler(&fakeScanner{}, reader)
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/qr/history", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var got []models.CoinAllocationHistory
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 1 || got[0].EventTypeName != "Raffle" {
		t.Errorf("unexpected history response: %+v", got)
	}
}

func TestHistory_EmptyReturnsEmptyArrayNotNull(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{history: nil})
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/qr/history", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if w.Body.String() != "[]" {
		t.Errorf("expected empty JSON array, got %q", w.Body.String())
	}
}

func TestHistory_RepoError_Returns500(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{historyErr: errors.New("db down")})
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/qr/history", nil)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", w.Code)
	}
}

func TestSummary_Success(t *testing.T) {
	reader := &fakeReader{summary: models.CoinAllocationSummary{TotalPending: 5, TotalTransferred: 10}}
	h := NewCoinHandler(&fakeScanner{}, reader)
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/qr/summary", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var got models.CoinAllocationSummary
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got.TotalPending != 5 || got.TotalTransferred != 10 {
		t.Errorf("unexpected summary response: %+v", got)
	}
}

func TestSummary_MissingUser_Returns401(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{})
	r := newTestRouter(h, nil)

	w := doRequest(r, http.MethodGet, "/qr/summary", nil)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestSummary_RepoError_Returns500(t *testing.T) {
	h := NewCoinHandler(&fakeScanner{}, &fakeReader{summaryErr: errors.New("db down")})
	r := newTestRouter(h, testUser)

	w := doRequest(r, http.MethodGet, "/qr/summary", nil)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", w.Code)
	}
}
