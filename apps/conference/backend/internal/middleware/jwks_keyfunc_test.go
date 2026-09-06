// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
//
// Licensed under the Apache License, Version 2.0 (see file header in auth.go).

package middleware

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TestJWKSKeyfunc_IgnoresMalformedX5C proves the loader validates a real RS256
// token even when the JWKS carries a bogus x5c/x5t#S256 alongside valid n/e --
// the exact shape Asgardeo serves (see the jwkKey doc comment). A cert-based
// loader discards such a key and every token fails as "unverifiable".
func TestJWKSKeyfunc_IgnoresMalformedX5C(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const kid = "test-kid_RS256"

	jwks := map[string]any{"keys": []map[string]any{{
		"kty":      "RSA",
		"kid":      kid,
		"use":      "sig",
		"alg":      "RS256",
		"n":        base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
		"e":        base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
		"x5c":      []string{"not-a-real-certificate"},         // bogus on purpose
		"x5t#S256": "aGV4LWVuY29kZWQtbm90LWJhc2U2NHVybC1yYXc", // Asgardeo-style malformed thumbprint
	}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jwks)
	}))
	defer srv.Close()

	kf, err := newJWKSKeyfunc(srv.URL, time.Hour)
	if err != nil {
		t.Fatalf("newJWKSKeyfunc: %v", err)
	}

	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": "https://issuer.example", "aud": "aud1", "sub": "user-1",
		"email": "a@b.com", "exp": time.Now().Add(time.Hour).Unix(),
	})
	tok.Header["kid"] = kid
	signed, err := tok.SignedString(priv)
	if err != nil {
		t.Fatal(err)
	}

	parsed, err := jwt.Parse(signed, kf, jwt.WithIssuer("https://issuer.example"), jwt.WithAudience("aud1"))
	if err != nil || !parsed.Valid {
		t.Fatalf("expected valid token, got err=%v valid=%v", err, parsed != nil && parsed.Valid)
	}
}

// TestJWKSKeyfunc_EmptySetFailsStartup guards the fail-fast contract main.go
// relies on: a JWKS with no usable key must error, not return a keyfunc.
func TestJWKSKeyfunc_EmptySetFailsStartup(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"keys":[]}`))
	}))
	defer srv.Close()
	if _, err := newJWKSKeyfunc(srv.URL, time.Hour); err == nil {
		t.Fatal("expected error for empty JWKS, got nil")
	}
}

// TestJWKSKeyfunc_RejectsWrongKid confirms a token whose kid is absent fails.
func TestJWKSKeyfunc_RejectsWrongKid(t *testing.T) {
	priv, _ := rsa.GenerateKey(rand.Reader, 2048)
	jwks := map[string]any{"keys": []map[string]any{{
		"kty": "RSA", "kid": "known_RS256",
		"n": base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
	}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jwks)
	}))
	defer srv.Close()
	kf, err := newJWKSKeyfunc(srv.URL, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{"sub": "x"})
	tok.Header["kid"] = "unknown_RS256"
	signed, _ := tok.SignedString(priv)
	if _, err := jwt.Parse(signed, kf); err == nil {
		t.Fatal("expected failure for unknown kid, got nil")
	}
}
