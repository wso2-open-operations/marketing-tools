// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package sheets

import "testing"

func strPtr(s string) *string { return &s }

func TestBuildSyncRows(t *testing.T) {
	rows := buildSyncRows([]AttendeeSummary{
		{Agenda: "Day 1", Username: "attendee@wso2.com", ScannedBy: strPtr("admin@wso2.com"), UserType: "Internal"},
		{Agenda: "Day 1", Username: "ext@example.com", ScannedBy: nil, UserType: "External"},
	}, "Last updated on: now")

	if len(rows) != 4 { // last-updated line + header + 2 data rows
		t.Fatalf("expected 4 rows, got %d", len(rows))
	}
	if rows[0][0] != "Last updated on: now" {
		t.Errorf("row 0 = %+v", rows[0])
	}
	wantHeader := []interface{}{sheetHeaderAgenda, sheetHeaderUsername, sheetHeaderUserType, sheetHeaderScannedBy}
	for i, v := range wantHeader {
		if rows[1][i] != v {
			t.Errorf("header[%d] = %v, want %v", i, rows[1][i], v)
		}
	}
	if rows[2][0] != "Day 1" || rows[2][1] != "attendee@wso2.com" || rows[2][2] != "Internal" || rows[2][3] != "admin@wso2.com" {
		t.Errorf("data row 0 = %+v", rows[2])
	}
	if rows[3][3] != "" {
		t.Errorf("expected empty scannedBy for nil pointer, got %v", rows[3][3])
	}
}
