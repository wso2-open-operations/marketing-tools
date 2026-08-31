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
	// Pointer + binding:"required" so an explicit 0 stays valid while an
	// omitted field is rejected (a bare float64 can't distinguish the two).
	TimeZoneOffset *float64 `json:"timeZoneOffset" binding:"required"`
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

	if err := h.sheets.SyncAttendeeSummary(c.Request.Context(), sheetSummaries, *payload.TimeZoneOffset); err != nil {
		slog.ErrorContext(c.Request.Context(), "Error syncing attendee summary to the sheet.", "error", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	slog.DebugContext(c.Request.Context(), fmt.Sprintf("Attendee summary synced successfully by the user: %s", userInfo.Email))
	c.Status(http.StatusOK)
}
