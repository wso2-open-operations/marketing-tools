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

// testKey is a synthetic 32-byte key (sequential bytes) used only by this
// test file. It has no relationship to any real PII_ENCRYPTION_KEY.
var testKey = mustDecodeKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

func mustDecodeKey(b64 string) []byte {
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		panic(err)
	}
	return k
}

func TestDecryptPII_KnownVectors(t *testing.T) {
	// These ciphertexts were generated once via EncryptPII(plaintext, testKey)
	// and hardcoded here as golden vectors, so this test also pins the exact
	// wire format: 1-byte version + 12-byte GCM nonce + ciphertext + 16-byte
	// tag, base64-encoded, no AAD.
	cases := []struct {
		ciphertext string
		want       string
	}{
		{"AUERhocGoKc+AsBmrtoRAyx6j4j6ZL47TqXO4EEgHpe1O874J47+GMc=", "Ada Lovelace"},
		{"AfM2VVvHG8CzCeEH+2bpb6EzjObcABQLxT0XWB6DndfseysWAwQt9Q==", "Alan Turing"},
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

	ciphertext, err := encryptPII(plaintext, testKey)
	if err != nil {
		t.Fatalf("encryptPII returned error: %v", err)
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
	_, err := DecryptPII("AUERhocGoKc+AsBmrtoRAyx6j4j6ZL47TqXO4EEgHpe1O874J47+GMc=", []byte("too-short"))
	if err == nil {
		t.Fatal("expected error for non-32-byte key, got nil")
	}
}

func TestDecryptPII_RejectsUnknownVersionByte(t *testing.T) {
	raw, err := base64.StdEncoding.DecodeString("AUERhocGoKc+AsBmrtoRAyx6j4j6ZL47TqXO4EEgHpe1O874J47+GMc=")
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
	raw, err := base64.StdEncoding.DecodeString("AUERhocGoKc+AsBmrtoRAyx6j4j6ZL47TqXO4EEgHpe1O874J47+GMc=")
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
