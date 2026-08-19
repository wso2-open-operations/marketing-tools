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

	"attendee-registration/internal/sheets"

	"github.com/gin-gonic/gin"
)

type SyncHandler struct {
	repo   SummaryRepository
	sheets SheetsClient
}

func NewSyncHandler(repo SummaryRepository, sheetsClient SheetsClient) *SyncHandler {
	return &SyncHandler{repo: repo, sheets: sheetsClient}
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
