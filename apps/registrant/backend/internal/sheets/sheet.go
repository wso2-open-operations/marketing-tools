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

	sheetsapi "google.golang.org/api/sheets/v4"
)

const (
	sheetHeaderAgenda    = "Agenda"
	sheetHeaderUsername  = "Username"
	sheetHeaderUserType  = "Type"
	sheetHeaderScannedBy = "Scanned By"
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
