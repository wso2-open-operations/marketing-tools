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

// Package crypto provides field-level encryption for PII data stored in the
// database (e.g. speaker company/LinkedIn URL). It wraps AES-256-GCM with a
// package-level key that must be set once via Init before any Encrypt/Decrypt
// calls are made.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
)

// currentVersion is the version byte prepended to every ciphertext produced
// by Encrypt. It is reserved for future key-rotation / algorithm-migration
// dispatch inside Decrypt.
const currentVersion byte = 1

const (
	nonceSize  = 12
	minTagSize = 16
)

// key holds the AES-256 key set via Init. It is intentionally not guarded by
// a mutex: Init is called exactly once at process startup, before any HTTP
// traffic is served, so there is no concurrent access to worry about.
var key []byte

// Init sets the package-level encryption key used by Encrypt/Decrypt. It
// must be called once at process startup before any HTTP traffic. key must
// be exactly 32 bytes (AES-256); if not, Init returns an error and leaves
// any previously stored key untouched.
func Init(k []byte) error {
	if len(k) != 32 {
		return fmt.Errorf("crypto: invalid key length %d, want 32 bytes for AES-256", len(k))
	}
	key = append([]byte(nil), k...)
	return nil
}

// Encrypt encrypts plaintext with AES-256-GCM using the package key set by
// Init. Empty strings are passed through unchanged (returned as "", nil)
// since several PII fields are nullable/blank and we don't want to pay AES
// overhead or produce ciphertext for blank data.
//
// The returned string is base64.StdEncoding of:
//
//	version_byte || nonce (12 bytes) || ciphertext+tag
func Encrypt(plaintext string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	if key == nil {
		return "", errors.New("crypto: encryption key not initialized")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("crypto: creating cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("crypto: creating GCM: %w", err)
	}

	nonce := make([]byte, nonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("crypto: generating nonce: %w", err)
	}

	sealed := gcm.Seal(nil, nonce, []byte(plaintext), nil)

	out := make([]byte, 0, 1+len(nonce)+len(sealed))
	out = append(out, currentVersion)
	out = append(out, nonce...)
	out = append(out, sealed...)

	return base64.StdEncoding.EncodeToString(out), nil
}

// Decrypt reverses Encrypt. Empty strings are passed through unchanged
// (returned as "", nil). Malformed, truncated, or tampered input always
// results in an error rather than a panic or garbage plaintext - callers
// (including code that speculatively calls Decrypt to check idempotency on
// values that may not actually be ciphertext) can rely on that.
func Decrypt(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	if key == nil {
		return "", errors.New("crypto: encryption key not initialized")
	}

	raw, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return "", fmt.Errorf("crypto: decoding base64: %w", err)
	}

	if len(raw) < 1+nonceSize+minTagSize {
		return "", errors.New("crypto: ciphertext too short")
	}

	version := raw[0]
	if version != currentVersion {
		return "", fmt.Errorf("crypto: unsupported ciphertext version %d", version)
	}
	body := raw[1:]

	nonce := body[:nonceSize]
	sealed := body[nonceSize:]

	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("crypto: creating cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("crypto: creating GCM: %w", err)
	}

	plaintext, err := gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return "", fmt.Errorf("crypto: decryption failed: %w", err)
	}

	return string(plaintext), nil
}

// EncryptPtr encrypts *s in place semantics: a nil pointer is passed through
// unchanged (returned as nil, nil, never touched/encrypted), matching the
// required behavior for nullable speaker fields such as company and
// linkedin_url. A non-nil pointer is encrypted via Encrypt and the result
// wrapped in a new *string.
func EncryptPtr(s *string) (*string, error) {
	if s == nil {
		return nil, nil
	}
	enc, err := Encrypt(*s)
	if err != nil {
		return nil, err
	}
	return &enc, nil
}

// DecryptPtr is the inverse of EncryptPtr: a nil pointer is passed through
// unchanged (returned as nil, nil); a non-nil pointer is decrypted via
// Decrypt and the result wrapped in a new *string.
func DecryptPtr(s *string) (*string, error) {
	if s == nil {
		return nil, nil
	}
	dec, err := Decrypt(*s)
	if err != nil {
		return nil, err
	}
	return &dec, nil
}
