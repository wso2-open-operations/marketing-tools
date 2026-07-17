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

// Package crypto decrypts PII fields (speaker name/title/bio, etc.) that are
// encrypted at rest in the shared marketingops schema by whatever process
// writes them. The wire format was reverse-engineered from real data: a
// 1-byte version marker, a 12-byte AES-GCM nonce, then the AES-256-GCM
// ciphertext with its 16-byte tag appended, all base64-encoded, with no
// additional authenticated data.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"fmt"
)

// pkgVersion is the only ciphertext version this package understands.
const pkgVersion = 0x01

// DecryptPII decrypts a base64-encoded ciphertext produced by whatever wrote
// it to the shared marketingops schema (version byte + nonce + ciphertext +
// tag), using key (must be exactly 32 bytes, for AES-256).
func DecryptPII(ciphertext string, key []byte) (string, error) {
	block, err := newAESBlock(key)
	if err != nil {
		return "", err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("crypto: constructing GCM: %w", err)
	}

	raw, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return "", fmt.Errorf("crypto: decoding base64: %w", err)
	}

	minLen := 1 + gcm.NonceSize()
	if len(raw) < minLen {
		return "", fmt.Errorf("crypto: ciphertext too short: got %d bytes, need at least %d", len(raw), minLen)
	}

	version := raw[0]
	if version != pkgVersion {
		return "", fmt.Errorf("crypto: unsupported ciphertext version %d", version)
	}

	nonce := raw[1 : 1+gcm.NonceSize()]
	sealed := raw[1+gcm.NonceSize():]

	plaintext, err := gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return "", fmt.Errorf("crypto: decrypting: %w", err)
	}

	return string(plaintext), nil
}

// EncryptPII encrypts plaintext into the same versioned format DecryptPII
// expects. It exists mainly to support round-trip testing of the scheme;
// nothing in this service currently writes encrypted PII.
func EncryptPII(plaintext string, key []byte) (string, error) {
	block, err := newAESBlock(key)
	if err != nil {
		return "", err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("crypto: constructing GCM: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("crypto: generating nonce: %w", err)
	}

	sealed := gcm.Seal(nil, nonce, []byte(plaintext), nil)

	raw := make([]byte, 0, 1+len(nonce)+len(sealed))
	raw = append(raw, pkgVersion)
	raw = append(raw, nonce...)
	raw = append(raw, sealed...)

	return base64.StdEncoding.EncodeToString(raw), nil
}

func newAESBlock(key []byte) (cipher.Block, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("crypto: key must be 32 bytes for AES-256, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("crypto: constructing AES cipher: %w", err)
	}
	return block, nil
}
