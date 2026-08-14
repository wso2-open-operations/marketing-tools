// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package email

import (
	"encoding/base64"
	"strings"
)

// BindKeyValues replaces each "<!-- [KEY] -->" placeholder in content with
// its corresponding value (keys are matched case-insensitively via
// upper-casing, matching the placeholders' all-caps convention in
// templates.go) and returns the result base64-encoded, ready for the email
// service's Payload.Template field.
func BindKeyValues(content string, keyValPairs map[string]string) string {
	bound := content
	for key, val := range keyValPairs {
		placeholder := "<!-- [" + strings.ToUpper(key) + "] -->"
		bound = strings.ReplaceAll(bound, placeholder, val)
	}
	return base64.StdEncoding.EncodeToString([]byte(bound))
}
