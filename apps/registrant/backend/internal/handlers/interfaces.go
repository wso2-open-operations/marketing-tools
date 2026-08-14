// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package handlers

import (
	"context"

	"attendee-registration/internal/email"
	"attendee-registration/internal/repository"
	"attendee-registration/internal/sheets"
)

// AgendaRepository is satisfied by *repository.Repository; declared here so
// handler tests can substitute a mock.
type AgendaRepository interface {
	GetAgendas(ctx context.Context, eventID string) ([]repository.Agenda, error)
	InsertAgendaAttendee(ctx context.Context, attendeeID, agendaID, userEmail string) error
	GetAgendaAttendee(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error)
	GetAgendaAttendeeCount(ctx context.Context, agendaID int) (repository.AgendaAttendeeCount, error)
	GetCurrentEvent(ctx context.Context) (repository.Event, error)
}

// SummaryRepository is satisfied by *repository.Repository.
type SummaryRepository interface {
	GetAttendeeSummary(ctx context.Context) ([]repository.AttendeeSummary, error)
}

// SheetsClient is satisfied by *sheets.Client.
type SheetsClient interface {
	SyncAttendeeSummary(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error
	GetSheetData(ctx context.Context) ([]sheets.Attendee, error)
	UpdateAttendeeData(ctx context.Context, rowIndex int, attendee sheets.Attendee) error
}

// EmailClient is satisfied by *email.Client.
type EmailClient interface {
	Send(ctx context.Context, payload email.Payload) error
}
