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

package crypto

import (
	"encoding/base64"
	"testing"
)

// testKey is a throwaway 32-byte AES-256 key, not used anywhere real.
var testKey = mustDecodeKey("Mm/1cft4jPwxSou2SJ2Kau3iZXYZfeCun8PVxfNOj74=")

func mustDecodeKey(b64 string) []byte {
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		panic(err)
	}
	return k
}

func TestDecryptPII_KnownVectors(t *testing.T) {
	// These two ciphertexts were pulled from real rows in the shared
	// marketingops.speakers table during investigation, and decrypted with
	// the same key present in this service's .env (PII_ENCRYPTION_KEY). They
	// pin the exact wire format: 1-byte version + 12-byte GCM nonce +
	// ciphertext + 16-byte tag, base64-encoded, no AAD.
	cases := []struct {
		ciphertext string
		want       string
	}{
		{"Ae7+z1RiFkxOn7mn79tPM1H7LPhi02iAZjeCx9RlkiVmJVN8zP0v", "Jay Howell"},
		{"AWGIKfPy4ccteFWLwB3Q9K7tr0y3AAEVBIcPEZNXQep4iYzL/EbWw9E=", "Ganesh Hegde"},
	}

	for _, c := range cases {
		got, err := DecryptPII(c.ciphertext, testKey)
		if err != nil {
			t.Fatalf("DecryptPII(%q) returned error: %v", c.ciphertext, err)
		}
		if got != c.want {
			t.Errorf("DecryptPII(%q) = %q, want %q", c.ciphertext, got, c.want)
		}
	}
}

func TestDecryptPII_RoundTrip(t *testing.T) {
	plaintext := "Round trip test with unicode: café ☕"

	ciphertext, err := EncryptPII(plaintext, testKey)
	if err != nil {
		t.Fatalf("EncryptPII returned error: %v", err)
	}

	got, err := DecryptPII(ciphertext, testKey)
	if err != nil {
		t.Fatalf("DecryptPII returned error: %v", err)
	}
	if got != plaintext {
		t.Errorf("round trip = %q, want %q", got, plaintext)
	}
}

func TestDecryptPII_RejectsWrongKeyLength(t *testing.T) {
	_, err := DecryptPII("Ae7+z1RiFkxOn7mn79tPM1H7LPhi02iAZjeCx9RlkiVmJVN8zP0v", []byte("too-short"))
	if err == nil {
		t.Fatal("expected error for non-32-byte key, got nil")
	}
}

func TestDecryptPII_RejectsUnknownVersionByte(t *testing.T) {
	raw, err := base64.StdEncoding.DecodeString("Ae7+z1RiFkxOn7mn79tPM1H7LPhi02iAZjeCx9RlkiVmJVN8zP0v")
	if err != nil {
		t.Fatalf("failed to decode fixture: %v", err)
	}
	raw[0] = 0x02 // corrupt the version byte
	corrupted := base64.StdEncoding.EncodeToString(raw)

	_, err = DecryptPII(corrupted, testKey)
	if err == nil {
		t.Fatal("expected error for unknown version byte, got nil")
	}
}

func TestDecryptPII_RejectsTruncatedCiphertext(t *testing.T) {
	// Too short to even contain a version byte + nonce.
	tooShort := base64.StdEncoding.EncodeToString([]byte{0x01, 0x02, 0x03})

	_, err := DecryptPII(tooShort, testKey)
	if err == nil {
		t.Fatal("expected error for truncated ciphertext, got nil")
	}
}

func TestDecryptPII_RejectsInvalidBase64(t *testing.T) {
	_, err := DecryptPII("not-valid-base64!!!", testKey)
	if err == nil {
		t.Fatal("expected error for invalid base64, got nil")
	}
}

func TestDecryptPII_RejectsTamperedTag(t *testing.T) {
	raw, err := base64.StdEncoding.DecodeString("Ae7+z1RiFkxOn7mn79tPM1H7LPhi02iAZjeCx9RlkiVmJVN8zP0v")
	if err != nil {
		t.Fatalf("failed to decode fixture: %v", err)
	}
	raw[len(raw)-1] ^= 0xFF // flip a bit in the GCM tag
	tampered := base64.StdEncoding.EncodeToString(raw)

	_, err = DecryptPII(tampered, testKey)
	if err == nil {
		t.Fatal("expected error for tampered ciphertext/tag, got nil")
	}
}
