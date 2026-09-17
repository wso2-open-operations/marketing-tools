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
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

const (
	jwtAssertionHeader  = "x-jwt-assertion"
	authorizationHeader = "Authorization"
	bearerPrefix        = "Bearer "
)

type contextKey string

const userInfoKey contextKey = "user-info"

// UserInfo holds the authenticated invoker's identity extracted from the JWT.
//
// Deliberately narrower than apps/conference/backend's UserInfo of the same
// name: this service has no role-gated route (see the AUTHORIZED_ROLE removal
// in internal/config), so it decodes no `groups`/`roles` claim, and it forwards
// the token to no downstream service, so it keeps no RawToken. Email is the
// only claim any handler reads -- it is written to attendee_registration as the
// scanning user -- and UserID is carried for log/debug parity with the
// conference backend.
type UserInfo struct {
	Email  string
	UserID string // JWT sub claim
}

// AuthConfig holds JWT validation configuration. Field-for-field the same
// contract as apps/conference/backend/internal/middleware.AuthConfig, so the
// two services are configured from the same Asgardeo values.
type AuthConfig struct {
	JWKSEndpoint string
	Issuer       string
	// Audiences is the set of `aud` values this deployment accepts, in OR
	// fashion: a token is valid when its aud claim names at least one of them
	// (see audienceAllowed). A list rather than a single value because the
	// registrant microapp and the conference backend's reverse proxy can mint
	// tokens under different Asgardeo applications, each stamping its own
	// client id as the audience. Only consulted when TokenValidatorEnabled.
	Audiences             []string
	ClockSkew             time.Duration
	TokenValidatorEnabled bool
}

type jwtClaims struct {
	Email                string `json:"email"`
	jwt.RegisteredClaims        // Sub carries the user UUID
}

// Auth returns a Gin middleware that validates the x-jwt-assertion header on
// every request and stores the resulting UserInfo in the request context.
//
// When AuthConfig.TokenValidatorEnabled is false the token is only decoded
// without signature verification (see extractUserInfo's ParseUnverified path):
// forged and expired tokens are accepted, so this is for local development
// ONLY. Production can never reach this branch -- main.go fails closed at
// startup when TOKEN_VALIDATOR_ENABLED is false in a production environment
// (see config.InsecureAuthConfig), so a prod container never boots with the
// validator off.
//
// This replaces the previous JwtInterceptor, a straight port of the Ballerina
// service's interceptor that base64-decoded the payload and trusted it
// outright. That trusted the Choreo gateway to have validated the token and
// trusted network placement to make the container unreachable any other way;
// anything that could reach the service directly could mint an
// x-jwt-assertion naming any email and, through POST /attendees/sync, write to
// the shared Google Sheet.
func Auth(cfg AuthConfig) gin.HandlerFunc {
	var keyFunc jwt.Keyfunc
	if cfg.TokenValidatorEnabled {
		kf, err := newJWKSKeyfunc(cfg.JWKSEndpoint, jwksRefreshInterval)
		if err != nil {
			panic("auth: failed to initialise JWKS from " + cfg.JWKSEndpoint + ": " + err.Error())
		}
		keyFunc = kf
	}

	return func(c *gin.Context) {
		candidates := candidateTokens(c.Request.Header)
		if len(candidates) == 0 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing authorization token"})
			return
		}

		info, err := firstValidToken(candidates, cfg, keyFunc)
		if err != nil {
			slog.WarnContext(c.Request.Context(), "auth: token validation failed", "err", err)
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}

		ctx := context.WithValue(c.Request.Context(), userInfoKey, info)
		c.Request = c.Request.WithContext(ctx)
		c.Next()
	}
}

// candidateTokens returns every JWT the request offers, in preference order:
// the gateway's x-jwt-assertion first, then the client's own Authorization
// Bearer token.
//
// Both are accepted because this service sits behind a gateway whose behaviour
// is not visible from here, while the microapp in front of it
// (digiops-marketing/apps/conference-attendee-registration-app) sends ONLY
// `Authorization: Bearer <Asgardeo id_token>` -- it never sets x-jwt-assertion
// (microapp/src/utils/http.js). Which header survives depends on the gateway:
// the WSO2/Choreo gateway in front of the original Ballerina service injected
// an x-jwt-assertion (that service read nothing else), but the staging Choreo
// gateway for the conference backend does not inject one at all. Reading only
// one header makes this service's success depend on a console-only gateway
// setting that lives nowhere in this repo; reading both means the caller is
// authenticated whichever survives.
//
// This costs nothing in strictness: every candidate goes through exactly the
// same verification in firstValidToken. An unverifiable header is not a
// fallback to "trust the other one blindly" -- it is simply not a valid token.
func candidateTokens(h http.Header) []string {
	var out []string
	if v := strings.TrimSpace(h.Get(jwtAssertionHeader)); v != "" {
		out = append(out, v)
	}
	if v := strings.TrimSpace(h.Get(authorizationHeader)); v != "" {
		// Case-insensitive scheme match: RFC 7235 makes the scheme token
		// case-insensitive and gateways rewrite it inconsistently.
		if len(v) > len(bearerPrefix) && strings.EqualFold(v[:len(bearerPrefix)], bearerPrefix) {
			if tok := strings.TrimSpace(v[len(bearerPrefix):]); tok != "" {
				out = append(out, tok)
			}
		}
	}
	return out
}

// firstValidToken returns the UserInfo of the first candidate that validates.
// If none does, it returns the FIRST candidate's error rather than the last:
// x-jwt-assertion is the header a correctly-configured gateway supplies, so its
// failure is the one that explains the 401 in the logs.
func firstValidToken(candidates []string, cfg AuthConfig, keyFunc jwt.Keyfunc) (*UserInfo, error) {
	var firstErr error
	for _, tok := range candidates {
		info, err := extractUserInfo(tok, cfg, keyFunc)
		if err == nil {
			return info, nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return nil, firstErr
}

// jwksRefreshInterval is how often the signing keys are re-fetched so that an
// IdP key rotation is picked up without a restart. Asgardeo rotates rarely, so
// an hour is ample and keeps request-path work to an in-memory map lookup.
const jwksRefreshInterval = time.Hour

// jwkKey is one entry of an RS256 JWKS document: the key id plus the RSA public
// key as its raw modulus (n) and exponent (e). We deliberately read only these
// fields and ignore x5c/x5t. Asgardeo's JWKS ships an x5c whose certificate has
// a negative serial number and an x5t#S256 that is a hex string rather than the
// spec's base64url(raw SHA-256); Go 1.23+ crypto/x509 rejects the former and
// the strict jwkset parser rejects the latter, so a cert-based loader (e.g.
// keyfunc.NewDefault) discards the whole key and every token then fails as
// "unverifiable". The n/e values are well-formed, so we build the key from them.
type jwkKey struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwksDoc struct {
	Keys []jwkKey `json:"keys"`
}

// newJWKSKeyfunc fetches the JWKS once (returning an error if that first fetch
// yields no usable key, so startup fails fast on a misconfigured endpoint) and
// then refreshes it in the background every refresh interval. The returned
// jwt.Keyfunc resolves the token's kid against the current key set.
func newJWKSKeyfunc(endpoint string, refresh time.Duration) (jwt.Keyfunc, error) {
	var store atomic.Pointer[map[string]*rsa.PublicKey]

	keys, err := fetchJWKS(endpoint)
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("JWKS at %s contained no usable RSA keys", endpoint)
	}
	store.Store(&keys)

	go func() {
		ticker := time.NewTicker(refresh)
		defer ticker.Stop()
		for range ticker.C {
			refreshed, err := fetchJWKS(endpoint)
			if err != nil {
				slog.Warn("auth: JWKS refresh failed, keeping previous keys", "err", err, "endpoint", endpoint)
				continue
			}
			if len(refreshed) == 0 {
				slog.Warn("auth: JWKS refresh returned no keys, keeping previous keys", "endpoint", endpoint)
				continue
			}
			store.Store(&refreshed)
		}
	}()

	return func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method %q", t.Header["alg"])
		}
		kid, _ := t.Header["kid"].(string)
		current := store.Load()
		if current != nil {
			if pk, ok := (*current)[kid]; ok {
				return pk, nil
			}
		}
		return nil, fmt.Errorf("no signing key for kid %q", kid)
	}, nil
}

// fetchJWKS retrieves the JWKS document and builds RSA public keys from the
// n/e parameters only. Keys without those parameters (or non-RSA keys) are
// skipped rather than failing the whole set.
func fetchJWKS(endpoint string) (map[string]*rsa.PublicKey, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(endpoint)
	if err != nil {
		return nil, fmt.Errorf("fetch JWKS: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch JWKS: unexpected status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read JWKS: %w", err)
	}
	var doc jwksDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("decode JWKS: %w", err)
	}

	keys := make(map[string]*rsa.PublicKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.N == "" || k.E == "" || k.Kid == "" {
			continue
		}
		nb, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			continue
		}
		eb, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{
			N: new(big.Int).SetBytes(nb),
			E: int(new(big.Int).SetBytes(eb).Int64()),
		}
	}
	return keys, nil
}

// audienceAllowed reports, as an error or its absence, whether a token's `aud`
// claim names at least one of the audiences this deployment accepts.
//
// Hand-rolled rather than handed to jwt.WithAudience, for the reason recorded
// at length in apps/conference/backend/internal/middleware/auth.go: in
// golang-jwt/jwt v5 WithAudience ASSIGNS rather than accumulates, so the
// intuitive one-call-per-audience spelling silently drops every audience but
// the last, and the "any of" vs "all of" distinction rests on two constructors
// one word apart. Comparing here makes the intended OR semantics readable and
// testable without minting signed tokens.
//
// A missing or empty aud is rejected, matching the library: a token this
// service cannot attribute to a registered application is not good enough to
// register attendees or push the summary sheet.
func audienceAllowed(tokenAud jwt.ClaimStrings, accepted []string) error {
	// Defence in depth against a caller constructing AuthConfig by hand with
	// the validator on and no audiences: config.Validate already refuses to
	// boot in that state, and an empty accepted set must never read as
	// "accept anything".
	if len(accepted) == 0 {
		return fmt.Errorf("token audience check: no accepted audiences configured")
	}

	// A JWT may carry aud as a bare string or an array; jwt.ClaimStrings
	// normalises both to a slice. An array of one empty string is how some
	// issuers spell "no audience", so it is filtered out here and treated as
	// missing, the same as the library's own verifyAudience does.
	present := make([]string, 0, len(tokenAud))
	for _, a := range tokenAud {
		if a != "" {
			present = append(present, a)
		}
	}
	if len(present) == 0 {
		return fmt.Errorf("token has no aud claim; accepted audiences are %v", accepted)
	}

	for _, a := range present {
		for _, want := range accepted {
			if a == want {
				return nil
			}
		}
	}

	// Both sides are named in the message on purpose: these are OAuth client
	// ids, not secrets, and they are the whole content of the failure. The
	// token itself is never logged -- it is a live bearer credential, and the
	// caller (Auth) logs only this error.
	return fmt.Errorf("token audience %v is not among the accepted audiences %v", present, accepted)
}

func extractUserInfo(tokenStr string, cfg AuthConfig, keyFunc jwt.Keyfunc) (*UserInfo, error) {
	var c jwtClaims

	if !cfg.TokenValidatorEnabled {
		if _, _, err := new(jwt.Parser).ParseUnverified(tokenStr, &c); err != nil {
			return nil, fmt.Errorf("decode token: %w", err)
		}
	} else {
		// No jwt.WithAudience here on purpose -- the audience is checked below
		// by audienceAllowed. Signature (via keyFunc), issuer, clock skew and a
		// mandatory exp stay with the library.
		token, err := jwt.ParseWithClaims(tokenStr, &c, keyFunc,
			jwt.WithIssuer(cfg.Issuer),
			jwt.WithLeeway(cfg.ClockSkew),
			jwt.WithExpirationRequired(),
		)
		if err != nil {
			return nil, fmt.Errorf("validate token: %w", err)
		}
		if !token.Valid {
			return nil, fmt.Errorf("invalid token")
		}
		// Ordered after ParseWithClaims so an unsigned, expired or
		// wrong-issuer token is rejected on those grounds first and its aud
		// claim -- attacker-controlled text until then -- is never the thing
		// we reason about, nor the thing we put in a log line.
		if err := audienceAllowed(c.Audience, cfg.Audiences); err != nil {
			return nil, err
		}
	}

	// Only email is required. Unlike the conference backend, no route here
	// reads `sub`, so a token without one is carried through with an empty
	// UserID rather than rejected -- refusing it would add a failure mode for
	// a claim this service never consults.
	if c.Email == "" {
		return nil, fmt.Errorf("token missing email claim")
	}

	return &UserInfo{
		Email:  c.Email,
		UserID: c.Subject,
	}, nil
}

// UserInfoFromContext retrieves the authenticated invoker's info from the
// context. Returns nil if the auth middleware was not applied.
func UserInfoFromContext(ctx context.Context) *UserInfo {
	v, _ := ctx.Value(userInfoKey).(*UserInfo)
	return v
}

// WithUserInfo returns a copy of ctx carrying the given UserInfo.
// Call this in tests to bypass JWT parsing and inject a fake authenticated user.
func WithUserInfo(ctx context.Context, user *UserInfo) context.Context {
	return context.WithValue(ctx, userInfoKey, user)
}
