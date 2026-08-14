// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package sheets

import (
	"testing"
	"time"
)

func TestGetFormattedDateTime_ParsesAsRFC1123Z(t *testing.T) {
	got := GetFormattedDateTime(0)
	if _, err := time.Parse(time.RFC1123Z, got); err != nil {
		t.Fatalf("GetFormattedDateTime(0) = %q is not RFC1123Z: %v", got, err)
	}
}

func TestGetFormattedDateTime_AppliesOffset(t *testing.T) {
	zero, err := time.Parse(time.RFC1123Z, GetFormattedDateTime(0))
	if err != nil {
		t.Fatalf("parse offset=0: %v", err)
	}
	plusFive, err := time.Parse(time.RFC1123Z, GetFormattedDateTime(5))
	if err != nil {
		t.Fatalf("parse offset=5: %v", err)
	}

	diff := plusFive.Sub(zero)
	want := 5 * time.Hour
	tolerance := 2 * time.Second // account for wall-clock drift between the two calls
	if diff < want-tolerance || diff > want+tolerance {
		t.Errorf("offset difference = %v, want ~%v", diff, want)
	}
}
