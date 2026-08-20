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

	"attendee-registration/internal/repository"
	"attendee-registration/internal/sheets"
)

// AgendaRepository is satisfied by *repository.Repository; declared here so
// handler tests can substitute a mock.
type AgendaRepository interface {
	GetAgendas(ctx context.Context, eventID string) ([]repository.Agenda, error)
	InsertAgendaAttendee(ctx context.Context, attendeeID, agendaID, userEmail string) error
	GetAgendaAttendee(ctx context.Context, attendeeID, agendaID string) (*repository.AgendaAttendee, error)
	GetAgendaAttendeeCount(ctx context.Context, agendaID string) (repository.AgendaAttendeeCount, error)
	GetCurrentEvent(ctx context.Context) (repository.Event, error)
}

// SummaryRepository is satisfied by *repository.Repository.
type SummaryRepository interface {
	GetAttendeeSummary(ctx context.Context) ([]repository.AttendeeSummary, error)
}

// SheetsClient is satisfied by *sheets.Client.
type SheetsClient interface {
	SyncAttendeeSummary(ctx context.Context, summaries []sheets.AttendeeSummary, timeZoneOffset float64) error
}
