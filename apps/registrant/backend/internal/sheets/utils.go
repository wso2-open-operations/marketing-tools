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

import "time"

// GetFormattedDateTime returns the current time shifted by timeZoneOffset
// hours, formatted as an RFC 5322 date-time string for display in the
// sheet's "last updated" line.
func GetFormattedDateTime(timeZoneOffset float64) string {
	shifted := time.Now().UTC().Add(time.Duration(timeZoneOffset * float64(time.Hour)))
	return shifted.Format(time.RFC1123Z)
}
