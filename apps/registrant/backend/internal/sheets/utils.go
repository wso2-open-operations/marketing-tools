// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package sheets

import "time"

// GetFormattedDateTime returns the current time shifted by timeZoneOffset
// hours, formatted as an RFC 5322 date-time string for display in the
// sheet's "last updated" line.
func GetFormattedDateTime(timeZoneOffset float64) string {
	shifted := time.Now().UTC().Add(time.Duration(timeZoneOffset * float64(time.Hour)))
	return shifted.Format(time.RFC1123Z)
}
