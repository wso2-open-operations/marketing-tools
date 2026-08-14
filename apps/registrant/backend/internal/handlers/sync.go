// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package handlers

import (
	"fmt"
	"log/slog"
	"net/http"

	"attendee-registration/internal/email"
	"attendee-registration/internal/sheets"

	"github.com/gin-gonic/gin"
)

type SyncHandler struct {
	repo      SummaryRepository
	sheets    SheetsClient
	emailer   EmailClient
	emailFrom string
}

func NewSyncHandler(repo SummaryRepository, sheetsClient SheetsClient, emailer EmailClient, emailFrom string) *SyncHandler {
	return &SyncHandler{repo: repo, sheets: sheetsClient, emailer: emailer, emailFrom: emailFrom}
}

type attendeeSyncPayload struct {
	TimeZoneOffset float64 `json:"timeZoneOffset"`
}

// SyncAttendees handles POST /attendees/sync.
func (h *SyncHandler) SyncAttendees(c *gin.Context) {
	userInfo, ok := requireUserInfo(c)
	if !ok {
		return
	}

	var payload attendeeSyncPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.Status(http.StatusBadRequest)
		return
	}

	summaries, err := h.repo.GetAttendeeSummary(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error retrieving attendee summary", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	sheetSummaries := make([]sheets.AttendeeSummary, len(summaries))
	for i, s := range summaries {
		sheetSummaries[i] = sheets.AttendeeSummary{
			Agenda:    s.Agenda,
			Username:  s.Username,
			ScannedBy: s.ScannedBy,
			UserType:  s.UserType,
		}
	}

	if err := h.sheets.SyncAttendeeSummary(c.Request.Context(), sheetSummaries, payload.TimeZoneOffset); err != nil {
		slog.ErrorContext(c.Request.Context(), "Error syncing attendee summary to the sheet.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	slog.DebugContext(c.Request.Context(), fmt.Sprintf("Attendee summary synced successfully by the user: %s", userInfo.Email))
	c.Status(http.StatusOK)
}

// SendInvitationNotifications handles POST /invitations/notifications: it
// emails every not-yet-invited attendee from the registration sheet their
// QR code and wallet pass link, marking each as sent once delivered. A
// failure for one attendee (template bind, send, or sheet update) is
// logged and skipped rather than aborting the rest of the batch.
func (h *SyncHandler) SendInvitationNotifications(c *gin.Context) {
	if _, ok := requireUserInfo(c); !ok {
		return
	}

	attendees, err := h.sheets.GetSheetData(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "Error while fetching sheet data", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	for idx, attendee := range attendees {
		if attendee.IsInviteSent {
			continue
		}
		// Row 1 is the header; sheet data starts at row 2 (A2:Z...), so the
		// Nth attendee (0-indexed) lives at row N+2.
		rowIndex := idx + 2

		content := email.BindKeyValues(email.RegistrantInvitationTemplate, map[string]string{
			"QR_IMAGE": fmt.Sprintf(`<img src="%s" style="border-radius: 10px;" alt="QR Code" width="300" />`,
				attendee.QRImageURL),
			"WALLET_PASS_LINK": fmt.Sprintf(
				`<a href="%s" style="line-height:45px;letter-spacing:1px;display:block ;text-decoration:none;color:#0d045c;">Add to Wallet</a>`,
				attendee.WalletPassURL),
		})

		if err := h.emailer.Send(c.Request.Context(), email.Payload{
			To:       []string{attendee.Email},
			From:     h.emailFrom,
			Subject:  "Your WSO2Con 2026 Digital Pass is Here!",
			Template: content,
		}); err != nil {
			slog.ErrorContext(c.Request.Context(),
				fmt.Sprintf("Error occurred while sending the email for attendee:%s", attendee.UUID), "error", err)
			continue
		}

		slog.InfoContext(c.Request.Context(), fmt.Sprintf("Email sent successfully to attendee:%s", attendee.UUID))
		attendee.IsInviteSent = true
		if err := h.sheets.UpdateAttendeeData(c.Request.Context(), rowIndex, attendee); err != nil {
			slog.ErrorContext(c.Request.Context(),
				fmt.Sprintf("Error occurred while updating the sheet for attendee:%s", attendee.UUID), "error", err)
			continue
		}
		slog.InfoContext(c.Request.Context(), fmt.Sprintf("Invite sent status updated for attendee:%s", attendee.UUID))
	}

	c.Status(http.StatusOK)
}
