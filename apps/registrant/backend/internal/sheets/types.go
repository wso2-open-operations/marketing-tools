// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package sheets

// Config holds the Google Sheets OAuth2 application configuration and the
// spreadsheet/sheet identifiers this package operates on.
type Config struct {
	ClientID              string
	ClientSecret          string
	RefreshToken          string
	TokenURL              string
	SpreadsheetID         string
	SheetID               int64
	SheetName             string
	SheetURL              string
	RegistrationSheetName string
	RegistrationSheetID   int64
}

// columnData indexes the registration sheet's columns.
var columnData = struct {
	Email      int
	UUID       int
	QRImage    int
	WalletPass int
	InviteSent int
}{
	Email:      0,
	UUID:       1,
	QRImage:    2,
	WalletPass: 3,
	InviteSent: 4,
}

// AttendeeSummary is one row of the attendee report synced to the sheet.
// Declared independently of repository.AttendeeSummary (rather than reused)
// to keep this package free of a repository dependency; callers convert.
type AttendeeSummary struct {
	Agenda    string
	Username  string
	ScannedBy *string
	UserType  string
}

// Attendee is a registration row read from/written to the registration
// sheet.
type Attendee struct {
	Email         string
	UUID          string
	QRImageURL    string
	WalletPassURL string
	IsInviteSent  bool
}
