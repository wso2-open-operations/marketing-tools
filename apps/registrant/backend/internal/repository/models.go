// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package repository

// Agenda is a scheduled session day for an event.
type Agenda struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Date string `json:"date"`
}

// AgendaAttendee records that an attendee has been registered for an agenda.
type AgendaAttendee struct {
	AttendeeID string `json:"attendeeId"`
	AgendaID   int    `json:"agendaId"`
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
