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

package sheets

// Config holds the Google Sheets OAuth2 application configuration and the
// spreadsheet/sheet identifiers this package operates on.
type Config struct {
	ClientID      string
	ClientSecret  string
	RefreshToken  string
	TokenURL      string
	SpreadsheetID string
	SheetID       int64
	SheetName     string
	SheetURL      string
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
