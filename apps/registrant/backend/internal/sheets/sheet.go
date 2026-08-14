// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package sheets

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	sheetsapi "google.golang.org/api/sheets/v4"
)

const (
	sheetHeaderAgenda    = "Agenda"
	sheetHeaderUsername  = "Username"
	sheetHeaderUserType  = "Type"
	sheetHeaderScannedBy = "Scanned By"
	a1NotationPrefix     = "A2:Z"
)

// SyncAttendeeSummary replaces the summary sheet's contents with a fresh
// "last updated" line, header row, and one row per attendee summary, then
// inserts a blank spacer row after the "last updated" line so the header
// row starts a clean table.
func (c *Client) SyncAttendeeSummary(ctx context.Context, summaries []AttendeeSummary, timeZoneOffset float64) error {
	if _, err := c.svc.Spreadsheets.Values.Clear(c.config.SpreadsheetID, c.config.SheetName, &sheetsapi.ClearValuesRequest{}).
		Context(ctx).Do(); err != nil {
		return fmt.Errorf("clear sheet: %w", err)
	}

	lastUpdatedText := fmt.Sprintf("Last updated on: %s", GetFormattedDateTime(timeZoneOffset))
	data := buildSyncRows(summaries, lastUpdatedText)

	if _, err := c.svc.Spreadsheets.Values.Append(c.config.SpreadsheetID, c.config.SheetName, &sheetsapi.ValueRange{Values: data}).
		ValueInputOption("RAW").Context(ctx).Do(); err != nil {
		return fmt.Errorf("append sheet values: %w", err)
	}

	insertReq := &sheetsapi.Request{
		InsertDimension: &sheetsapi.InsertDimensionRequest{
			Range: &sheetsapi.DimensionRange{
				SheetId:    c.config.SheetID,
				Dimension:  "ROWS",
				StartIndex: 1,
				EndIndex:   2,
			},
			InheritFromBefore: true,
		},
	}
	if _, err := c.svc.Spreadsheets.BatchUpdate(c.config.SpreadsheetID, &sheetsapi.BatchUpdateSpreadsheetRequest{
		Requests: []*sheetsapi.Request{insertReq},
	}).Context(ctx).Do(); err != nil {
		return fmt.Errorf("insert row after header: %w", err)
	}
	return nil
}

// buildSyncRows assembles the "last updated" line, header row, and one data
// row per summary, in the column order Agenda, Username, Type, Scanned By.
func buildSyncRows(summaries []AttendeeSummary, lastUpdatedText string) [][]interface{} {
	data := make([][]interface{}, 0, len(summaries)+2)
	data = append(data, []interface{}{lastUpdatedText})
	data = append(data, []interface{}{sheetHeaderAgenda, sheetHeaderUsername, sheetHeaderUserType, sheetHeaderScannedBy})
	for _, s := range summaries {
		scannedBy := ""
		if s.ScannedBy != nil {
			scannedBy = *s.ScannedBy
		}
		data = append(data, []interface{}{s.Agenda, s.Username, s.UserType, scannedBy})
	}
	return data
}

// GetSheetData returns every registration row from the registration sheet.
func (c *Client) GetSheetData(ctx context.Context) ([]Attendee, error) {
	spreadsheet, err := c.svc.Spreadsheets.Get(c.config.SpreadsheetID).Context(ctx).Do()
	if err != nil {
		return nil, fmt.Errorf("get spreadsheet: %w", err)
	}
	if len(spreadsheet.Sheets) == 0 {
		return nil, fmt.Errorf("spreadsheet has no sheets")
	}
	rowCount := spreadsheet.Sheets[0].Properties.GridProperties.RowCount
	a1Notation := fmt.Sprintf("%s%d", a1NotationPrefix, rowCount)
	rangeStr := fmt.Sprintf("%s!%s", quoteSheetName(c.config.RegistrationSheetName), a1Notation)

	valueRange, err := c.svc.Spreadsheets.Values.Get(c.config.SpreadsheetID, rangeStr).Context(ctx).Do()
	if err != nil {
		return nil, fmt.Errorf("get sheet range: %w", err)
	}
	return parseAttendeeRows(valueRange.Values), nil
}

// parseAttendeeRows converts raw sheet rows into Attendee records, skipping
// any row that doesn't have all five expected columns.
func parseAttendeeRows(rows [][]interface{}) []Attendee {
	attendees := []Attendee{}
	for _, row := range rows {
		if len(row) < 5 {
			continue
		}
		attendees = append(attendees, Attendee{
			Email:         fmt.Sprint(row[columnData.Email]),
			UUID:          fmt.Sprint(row[columnData.UUID]),
			QRImageURL:    fmt.Sprint(row[columnData.QRImage]),
			WalletPassURL: fmt.Sprint(row[columnData.WalletPass]),
			IsInviteSent:  fmt.Sprint(row[columnData.InviteSent]) == "true",
		})
	}
	return attendees
}

// UpdateAttendeeData overwrites the given 1-based row of the registration
// sheet with attendee's values.
func (c *Client) UpdateAttendeeData(ctx context.Context, rowIndex int, attendee Attendee) error {
	rangeStr := fmt.Sprintf("%s!A%d:E%d", quoteSheetName(c.config.RegistrationSheetName), rowIndex, rowIndex)
	values := [][]interface{}{{
		attendee.Email,
		attendee.UUID,
		attendee.QRImageURL,
		attendee.WalletPassURL,
		strconv.FormatBool(attendee.IsInviteSent),
	}}
	_, err := c.svc.Spreadsheets.Values.Update(c.config.SpreadsheetID, rangeStr, &sheetsapi.ValueRange{Values: values}).
		ValueInputOption("RAW").Context(ctx).Do()
	if err != nil {
		return fmt.Errorf("update sheet row: %w", err)
	}
	return nil
}

// quoteSheetName wraps a sheet name in single quotes (doubling any embedded
// quote) as required by A1 notation ranges once the name contains spaces or
// other special characters.
func quoteSheetName(name string) string {
	return "'" + strings.ReplaceAll(name, "'", "''") + "'"
}
