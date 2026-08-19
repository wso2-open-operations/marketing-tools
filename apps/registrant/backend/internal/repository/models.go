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

package repository

// Agenda is a scheduled session for an event. Sourced from the shared
// sessions/conference_days tables -- registrant no longer owns an agenda
// table.
type Agenda struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Date string `json:"date"`
}

// AgendaAttendee records that an attendee has been registered for an agenda
// (a session, per the shared schema).
type AgendaAttendee struct {
	AttendeeID string `json:"attendeeId"`
	AgendaID   string `json:"agendaId"`
}

// AgendaAttendeeCount breaks down an agenda's registered attendees by
// whether the attendee ID belongs to the internal (@wso2.com) domain.
type AgendaAttendeeCount struct {
	InternalCount int `json:"internalCount"`
	ExternalCount int `json:"externalCount"`
	TotalCount    int `json:"totalCount"`
}

// AttendeeSummary is one row of the current event's attendee report,
// joining an agenda registration back to its agenda name.
type AttendeeSummary struct {
	Agenda    string  `json:"agenda"`
	Username  string  `json:"username"`
	ScannedBy *string `json:"scannedBy"`
	UserType  string  `json:"userType"`
}

// Event is a conference event.
type Event struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Location string `json:"location"`
}
