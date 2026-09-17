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

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

func init() {
	gin.SetMode(gin.TestMode)
}

const (
	testIssuer = "https://issuer.example/oauth2/token"
	testAud    = "registrant-client-id"
	testKid    = "test-kid_RS256"
)

// devConfig is the validator-off configuration used by local development.
func devConfig() AuthConfig {
	return AuthConfig{ClockSkew: 5 * time.Minute, TokenValidatorEnabled: false}
}

// fakeJWT builds an unsigned token, i.e. exactly what the old JwtInterceptor
// accepted and what the validator-on path must now reject. The signature
// segment is base64url garbage rather than the literal "signature": v5's
// ParseUnverified still base64-decodes that segment, so a non-base64 value is
// rejected as malformed before the claims are ever read.
func fakeJWT(payloadJSON string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(payloadJSON))
	sig := base64.RawURLEncoding.EncodeToString([]byte("not-a-real-signature"))
	return header + "." + payload + "." + sig
}

func runAuth(cfg AuthConfig, req *http.Request) (*httptest.ResponseRecorder, *UserInfo) {
	w := httptest.NewRecorder()
	r := gin.New()
	var captured *UserInfo
	r.GET("/", Auth(cfg), func(c *gin.Context) {
		captured = UserInfoFromContext(c.Request.Context())
		c.Status(http.StatusOK)
	})
	r.ServeHTTP(w, req)
	return w, captured
}

func requestWithToken(token string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if token != "" {
		req.Header.Set(jwtAssertionHeader, token)
	}
	return req
}

// --- validator off (development) -------------------------------------------

func TestAuth_MissingHeader(t *testing.T) {
	w, captured := runAuth(devConfig(), requestWithToken(""))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	if captured != nil {
		t.Fatalf("expected handler not to run, got captured user info")
	}
}

func TestAuth_MalformedToken(t *testing.T) {
	w, _ := runAuth(devConfig(), requestWithToken("not-a-jwt"))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_InvalidBase64Payload(t *testing.T) {
	w, _ := runAuth(devConfig(), requestWithToken("header.not!valid!base64.signature"))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_InvalidJSONPayload(t *testing.T) {
	w, _ := runAuth(devConfig(), requestWithToken(fakeJWT("not json")))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_MissingEmail(t *testing.T) {
	w, captured := runAuth(devConfig(), requestWithToken(fakeJWT(`{"sub":"user-1"}`)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	if captured != nil {
		t.Fatalf("expected handler not to run, got captured user info")
	}
}

// TestAuth_ValidatorOffAcceptsUnsignedToken pins the development-only branch:
// with the validator off an unsigned token still passes, which is exactly why
// main.go refuses to boot in this state in production.
func TestAuth_ValidatorOffAcceptsUnsignedToken(t *testing.T) {
	w, captured := runAuth(devConfig(), requestWithToken(fakeJWT(`{"email":"attendee@wso2.com","sub":"user-1"}`)))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	if captured == nil {
		t.Fatal("expected user info to be captured")
	}
	if captured.Email != "attendee@wso2.com" {
		t.Fatalf("Email = %q, want %q", captured.Email, "attendee@wso2.com")
	}
	if captured.UserID != "user-1" {
		t.Fatalf("UserID = %q, want %q", captured.UserID, "user-1")
	}
}

// TestAuth_NoSubIsAccepted documents the one deliberate divergence from
// apps/conference/backend, which rejects a token without `sub`: no route here
// reads it, so it is carried through empty rather than becoming a 401.
func TestAuth_NoSubIsAccepted(t *testing.T) {
	w, captured := runAuth(devConfig(), requestWithToken(fakeJWT(`{"email":"attendee@wso2.com"}`)))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	if captured == nil || captured.UserID != "" {
		t.Fatalf("expected empty UserID, got %+v", captured)
	}
}

// --- validator on (staging/production) -------------------------------------

// signingSetup starts a JWKS server carrying the Asgardeo-shaped key (valid
// n/e alongside a bogus x5c/x5t#S256) and returns the private key plus a
// validator-on AuthConfig pointed at it.
func signingSetup(t *testing.T) (*rsa.PrivateKey, AuthConfig, func()) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	jwks := map[string]any{"keys": []map[string]any{{
		"kty":      "RSA",
		"kid":      testKid,
		"use":      "sig",
		"alg":      "RS256",
		"n":        base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
		"e":        base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
		"x5c":      []string{"not-a-real-certificate"},        // bogus on purpose
		"x5t#S256": "aGV4LWVuY29kZWQtbm90LWJhc2U2NHVybC1yYXc", // Asgardeo-style malformed thumbprint
	}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jwks)
	}))
	cfg := AuthConfig{
		JWKSEndpoint:          srv.URL,
		Issuer:                testIssuer,
		Audiences:             []string{testAud},
		ClockSkew:             5 * time.Minute,
		TokenValidatorEnabled: true,
	}
	return priv, cfg, srv.Close
}

func signToken(t *testing.T, priv *rsa.PrivateKey, claims jwt.MapClaims, kid string) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	signed, err := tok.SignedString(priv)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func validClaims() jwt.MapClaims {
	return jwt.MapClaims{
		"iss":   testIssuer,
		"aud":   testAud,
		"sub":   "user-uuid-1",
		"email": "attendee@wso2.com",
		"exp":   time.Now().Add(time.Hour).Unix(),
	}
}

func TestAuth_ValidatorOn_AcceptsSignedToken(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	w, captured := runAuth(cfg, requestWithToken(signToken(t, priv, validClaims(), testKid)))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (body %s)", w.Code, http.StatusOK, w.Body.String())
	}
	if captured == nil || captured.Email != "attendee@wso2.com" || captured.UserID != "user-uuid-1" {
		t.Fatalf("captured = %+v, want email/sub from the token", captured)
	}
}

// TestAuth_ValidatorOn_RejectsUnsignedToken is the whole point of this change:
// the token the old interceptor happily trusted must now be a 401.
func TestAuth_ValidatorOn_RejectsUnsignedToken(t *testing.T) {
	_, cfg, closeFn := signingSetup(t)
	defer closeFn()

	w, captured := runAuth(cfg, requestWithToken(fakeJWT(`{"email":"attacker@wso2.com","sub":"x","iss":"`+testIssuer+`","aud":"`+testAud+`"}`)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	if captured != nil {
		t.Fatal("expected handler not to run for an unsigned token")
	}
}

func TestAuth_ValidatorOn_RejectsWrongSigningKey(t *testing.T) {
	_, cfg, closeFn := signingSetup(t)
	defer closeFn()

	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	w, _ := runAuth(cfg, requestWithToken(signToken(t, other, validClaims(), testKid)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_RejectsExpiredToken(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	claims := validClaims()
	claims["exp"] = time.Now().Add(-2 * time.Hour).Unix()
	w, _ := runAuth(cfg, requestWithToken(signToken(t, priv, claims, testKid)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_RejectsMissingExp(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	claims := validClaims()
	delete(claims, "exp")
	w, _ := runAuth(cfg, requestWithToken(signToken(t, priv, claims, testKid)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_RejectsWrongIssuer(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	claims := validClaims()
	claims["iss"] = "https://evil.example"
	w, _ := runAuth(cfg, requestWithToken(signToken(t, priv, claims, testKid)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_RejectsWrongAudience(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	claims := validClaims()
	claims["aud"] = "some-other-app"
	w, _ := runAuth(cfg, requestWithToken(signToken(t, priv, claims, testKid)))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_RejectsUnknownKid(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	w, _ := runAuth(cfg, requestWithToken(signToken(t, priv, validClaims(), "unknown_RS256")))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidatorOn_AcceptsSecondConfiguredAudience(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()
	cfg.Audiences = []string{"conference-proxy-client", testAud}

	w, captured := runAuth(cfg, requestWithToken(signToken(t, priv, validClaims(), testKid)))

	if w.Code != http.StatusOK || captured == nil {
		t.Fatalf("status = %d captured = %+v, want 200 with user info", w.Code, captured)
	}
}

// --- header sourcing ------------------------------------------------------

func TestCandidateTokens(t *testing.T) {
	tests := []struct {
		name      string
		assertion string
		authz     string
		want      []string
	}{
		{"neither header", "", "", nil},
		{"assertion only", "tok-a", "", []string{"tok-a"}},
		{"bearer only", "", "Bearer tok-b", []string{"tok-b"}},
		{"both, assertion first", "tok-a", "Bearer tok-b", []string{"tok-a", "tok-b"}},
		{"lowercase scheme", "", "bearer tok-b", []string{"tok-b"}},
		{"mixed-case scheme", "", "BeArEr tok-b", []string{"tok-b"}},
		{"non-bearer scheme ignored", "", "Basic dXNlcjpwdw==", nil},
		{"bare bearer with no token", "", "Bearer ", nil},
		{"whitespace-only assertion", "   ", "", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := http.Header{}
			if tt.assertion != "" {
				h.Set(jwtAssertionHeader, tt.assertion)
			}
			if tt.authz != "" {
				h.Set(authorizationHeader, tt.authz)
			}
			got := candidateTokens(h)
			if len(got) != len(tt.want) {
				t.Fatalf("candidateTokens() = %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("candidateTokens() = %v, want %v", got, tt.want)
				}
			}
		})
	}
}

// TestAuth_AcceptsBearerWhenAssertionAbsent is the microapp's actual shape: it
// sends only Authorization: Bearer (microapp/src/utils/http.js), never
// x-jwt-assertion. If the gateway in front of this service does not inject one,
// the caller must still authenticate.
func TestAuth_AcceptsBearerWhenAssertionAbsent(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(authorizationHeader, "Bearer "+signToken(t, priv, validClaims(), testKid))
	w, captured := runAuth(cfg, req)

	if w.Code != http.StatusOK || captured == nil {
		t.Fatalf("status = %d captured = %+v, want 200 with user info", w.Code, captured)
	}
}

// TestAuth_FallsBackToBearerWhenAssertionUnverifiable covers the deployment the
// gateway actually produces: it mints its own X-JWT-Assertion, which does not
// verify against the IdP's JWKS. The client's own Bearer token must then carry
// the request.
func TestAuth_FallsBackToBearerWhenAssertionUnverifiable(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()

	gatewayKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, signToken(t, gatewayKey, validClaims(), testKid))
	req.Header.Set(authorizationHeader, "Bearer "+signToken(t, priv, validClaims(), testKid))
	w, captured := runAuth(cfg, req)

	if w.Code != http.StatusOK || captured == nil {
		t.Fatalf("status = %d captured = %+v, want 200 via the Bearer fallback", w.Code, captured)
	}
}

// TestAuth_RejectsWhenNeitherHeaderVerifies proves the fallback is not a
// weakening: two unverifiable tokens are still a 401.
func TestAuth_RejectsWhenNeitherHeaderVerifies(t *testing.T) {
	_, cfg, closeFn := signingSetup(t)
	defer closeFn()

	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, signToken(t, other, validClaims(), testKid))
	req.Header.Set(authorizationHeader, "Bearer "+signToken(t, other, validClaims(), testKid))
	w, captured := runAuth(cfg, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	if captured != nil {
		t.Fatal("expected handler not to run")
	}
}

// --- audienceAllowed --------------------------------------------------------

func TestAudienceAllowed(t *testing.T) {
	tests := []struct {
		name     string
		tokenAud jwt.ClaimStrings
		accepted []string
		wantErr  bool
	}{
		{"single match", jwt.ClaimStrings{"a"}, []string{"a"}, false},
		{"one of several", jwt.ClaimStrings{"b"}, []string{"a", "b", "c"}, false},
		{"token lists several, one accepted", jwt.ClaimStrings{"x", "b"}, []string{"b"}, false},
		{"no match", jwt.ClaimStrings{"z"}, []string{"a", "b"}, true},
		{"missing aud", nil, []string{"a"}, true},
		{"empty-string aud reads as missing", jwt.ClaimStrings{""}, []string{"a"}, true},
		{"no accepted audiences configured", jwt.ClaimStrings{"a"}, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := audienceAllowed(tt.tokenAud, tt.accepted)
			if (err != nil) != tt.wantErr {
				t.Fatalf("audienceAllowed(%v, %v) error = %v, wantErr %v", tt.tokenAud, tt.accepted, err, tt.wantErr)
			}
		})
	}
}

// --- JWKS loader ------------------------------------------------------------

// TestJWKSKeyfunc_EmptySetFailsStartup guards the fail-fast contract Auth
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

func TestJWKSKeyfunc_UnreachableEndpointFailsStartup(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	if _, err := newJWKSKeyfunc(srv.URL, time.Hour); err == nil {
		t.Fatal("expected error for a failing JWKS endpoint, got nil")
	}
}

// TestJWKSKeyfunc_RejectsNonRSAAlg pins the keyfunc's signing-method check: an
// HMAC token whose kid names a real RSA key must not resolve that key.
func TestJWKSKeyfunc_RejectsNonRSAAlg(t *testing.T) {
	priv, cfg, closeFn := signingSetup(t)
	defer closeFn()
	_ = priv

	kf, err := newJWKSKeyfunc(cfg.JWKSEndpoint, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims())
	tok.Header["kid"] = testKid
	signed, err := tok.SignedString([]byte("shared-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := jwt.Parse(signed, kf); err == nil {
		t.Fatal("expected failure for a non-RSA signing method, got nil")
	}
}

// --- context helpers --------------------------------------------------------

func TestWithUserInfo(t *testing.T) {
	ctx := WithUserInfo(httptest.NewRequest(http.MethodGet, "/", nil).Context(), &UserInfo{Email: "test@example.com"})
	got := UserInfoFromContext(ctx)
	if got == nil || got.Email != "test@example.com" {
		t.Fatalf("UserInfoFromContext() = %+v, want Email=test@example.com", got)
	}
}
