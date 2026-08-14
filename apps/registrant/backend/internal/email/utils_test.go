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
	"testing"
)

func TestBindKeyValues(t *testing.T) {
	content := `before <!-- [QR_IMAGE] --> middle <!-- [WALLET_PASS_LINK] --> after`

	got := BindKeyValues(content, map[string]string{
		"QR_IMAGE":         "<img src=\"qr.png\" />",
		"WALLET_PASS_LINK": "<a href=\"wallet\">Add</a>",
	})

	decoded, err := base64.StdEncoding.DecodeString(got)
	if err != nil {
		t.Fatalf("result is not valid base64: %v", err)
	}

	want := `before <img src="qr.png" /> middle <a href="wallet">Add</a> after`
	if string(decoded) != want {
		t.Errorf("decoded = %q, want %q", decoded, want)
	}
}

func TestBindKeyValues_UnmatchedPlaceholderLeftAsIs(t *testing.T) {
	content := `<!-- [QR_IMAGE] --> <!-- [WALLET_PASS_LINK] -->`

	got := BindKeyValues(content, map[string]string{"QR_IMAGE": "img"})

	decoded, err := base64.StdEncoding.DecodeString(got)
	if err != nil {
		t.Fatalf("result is not valid base64: %v", err)
	}
	if !strings.Contains(string(decoded), "<!-- [WALLET_PASS_LINK] -->") {
		t.Errorf("expected unmatched placeholder to remain, got %q", decoded)
	}
}

func TestBindKeyValues_RealTemplate(t *testing.T) {
	got := BindKeyValues(RegistrantInvitationTemplate, map[string]string{
		"QR_IMAGE":         `<img src="qr.png" />`,
		"WALLET_PASS_LINK": `<a href="wallet">Add to Wallet</a>`,
	})

	decoded, err := base64.StdEncoding.DecodeString(got)
	if err != nil {
		t.Fatalf("result is not valid base64: %v", err)
	}
	s := string(decoded)
	if strings.Contains(s, "<!-- [QR_IMAGE] -->") {
		t.Error("QR_IMAGE placeholder was not replaced")
	}
	if strings.Contains(s, "<!-- [WALLET_PASS_LINK] -->") {
		t.Error("WALLET_PASS_LINK placeholder was not replaced")
	}
	if !strings.Contains(s, `<img src="qr.png" />`) {
		t.Error("QR image markup missing from bound template")
	}
}
