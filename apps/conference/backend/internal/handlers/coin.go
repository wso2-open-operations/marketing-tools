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
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
	"wso2-coin-backend/internal/service"
)

// CoinScanner runs the QR-scan business workflow. Satisfied by *service.CoinService.
type CoinScanner interface {
	ScanQR(ctx context.Context, userID, email, qrID string, jwtAssertion string) error
}

// CoinHistoryReader reads a user's coin allocation history/summary. Satisfied by *repository.CoinAllocationRepo.
type CoinHistoryReader interface {
	History(ctx context.Context, userUUID, eventID string) ([]models.CoinAllocationHistory, error)
	Summary(ctx context.Context, userUUID, eventID string) (models.CoinAllocationSummary, error)
}

// CoinHandler exposes the WSO2 Coin / O2C HTTP endpoints.
type QrCatalogReader interface {
	GetQRCodes(ctx context.Context) (*models.ConferenceQrCodesResponse, error)
}

// CoinHandler exposes the WSO2 Coin / O2C HTTP endpoints.
type CoinHandler struct {
	scanner    CoinScanner
	reader     CoinHistoryReader
	catalog    QrCatalogReader
	events     repository.EventReader
	adminRoles []string
}

// NewCoinHandler constructs a CoinHandler.
func NewCoinHandler(scanner CoinScanner, reader CoinHistoryReader, catalog QrCatalogReader, events repository.EventReader, adminRoles []string) *CoinHandler {
	return &CoinHandler{scanner: scanner, reader: reader, catalog: catalog, events: events, adminRoles: adminRoles}
}

// Scan handles POST /qr/scan.
func (h *CoinHandler) Scan(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.QrScanRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}

	err := h.scanner.ScanQR(c.Request.Context(), user.UserID, user.Email, req.QrID, user.RawToken)
	switch {
	case err == nil:
		c.Status(http.StatusOK)
	case errors.Is(err, service.ErrNotRegisteredAttendee), errors.Is(err, service.ErrWSO2EmployeeNotEligible):
		c.JSON(http.StatusForbidden, gin.H{"message": err.Error()})
	case errors.Is(err, service.ErrQRAlreadyScanned),
		errors.Is(err, service.ErrWalletNotFound),
		errors.Is(err, service.ErrSessionNotStarted),
		errors.Is(err, service.ErrQRScanWindowExpired):
		c.JSON(http.StatusBadRequest, gin.H{"message": err.Error()})
	default:
		slog.ErrorContext(c.Request.Context(), "qr scan failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
	}
}

// History handles GET /qr/history.
func (h *CoinHandler) History(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	currentEvent, err := h.events.GetCurrentEvent(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to get current event", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	history, err := h.reader.History(c.Request.Context(), user.UserID, currentEvent.ID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching coin allocation history failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if history == nil {
		history = []models.CoinAllocationHistory{}
	}
	c.JSON(http.StatusOK, history)
}

// Summary handles GET /qr/summary.
func (h *CoinHandler) Summary(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	currentEvent, err := h.events.GetCurrentEvent(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to get current event", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	summary, err := h.reader.Summary(c.Request.Context(), user.UserID, currentEvent.ID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching coin allocation summary failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	c.JSON(http.StatusOK, summary)
}

// GetGeneratedQRs handles GET /qr/admin.
func (h *CoinHandler) GetGeneratedQRs(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	isAdmin := false
	for _, g := range user.Groups {
		for _, adminRole := range h.adminRoles {
			if g == adminRole {
				isAdmin = true
				break
			}
		}
		if isAdmin {
			break
		}
	}

	res, err := h.catalog.GetQRCodes(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "failed to fetch qr codes from portal", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}

	if isAdmin {
		c.JSON(http.StatusOK, res)
		return
	}

	// Not an admin: filter QRs based on user email domain
	emailParts := strings.Split(user.Email, "@")
	slog.InfoContext(c.Request.Context(), "GetGeneratedQRs: filtering for non-admin", "email", user.Email, "emailParts", len(emailParts))
	if len(emailParts) != 2 {
		c.JSON(http.StatusOK, models.ConferenceQrCodesResponse{Qrs: []models.ConferenceQrCode{}, TotalCount: 0})
		return
	}
	userDomain := emailParts[1]
	slog.InfoContext(c.Request.Context(), "GetGeneratedQRs: user domain identified", "userDomain", userDomain)

	var filtered []models.ConferenceQrCode
	for _, qr := range res.Qrs {
		if qr.Info.Domain == userDomain {
			filtered = append(filtered, qr)
		}
	}

	c.JSON(http.StatusOK, models.ConferenceQrCodesResponse{
		Qrs:        filtered,
		TotalCount: len(filtered),
	})
}
