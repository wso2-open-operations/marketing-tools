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
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

const jwtAssertionHeader = "x-jwt-assertion"

type contextKey string

const userInfoKey contextKey = "user-info"

// UserInfo holds the authenticated user's identity extracted from the JWT.
type UserInfo struct {
	Email      string
	UserID     string // JWT sub claim
	GivenName  string
	FamilyName string
	// Groups is the JWT groups claim, the IdP's role memberships for this
	// user. Only admin-gated routes read it (see HasAnyGroup); an absent
	// claim yields nil, which denies rather than allows.
	Groups []string
	// RawToken is the literal incoming x-jwt-assertion value, before any
	// parsing. The AI agent routes forward this verbatim to external AI
	// services (pure pass-through auth, see .claude/PLAN.md) -- everything
	// else uses the parsed claims above instead.
	RawToken string
}

// HasAnyGroup reports whether the user belongs to at least one of want.
// An empty want denies: an admin-gated route whose allow-list was never
// configured must not fall open to every authenticated caller.
func (u *UserInfo) HasAnyGroup(want []string) bool {
	for _, w := range want {
		for _, g := range u.Groups {
			if g == w {
				return true
			}
		}
	}
	return false
}

// AuthConfig holds JWT validation configuration.
type AuthConfig struct {
	JWKSEndpoint          string
	Issuer                string
	Audience              string
	ClockSkew             time.Duration
	TokenValidatorEnabled bool
}

type jwtClaims struct {
	Email                string   `json:"email"`
	GivenName            string   `json:"given_name"`
	FamilyName           string   `json:"family_name"`
	Groups               []string `json:"groups"`
	jwt.RegisteredClaims          // Sub carries the user UUID
}

// Auth returns a Gin middleware that validates the x-jwt-assertion header on
// every request and stores the resulting UserInfo in the request context.
// When AuthConfig.TokenValidatorEnabled is false the token is only decoded
// without signature verification (see extractUserInfo's ParseUnverified path):
// forged and expired tokens are accepted, so this is for local development
// ONLY. Production can never reach this branch -- main.go fails closed at
// startup when TOKEN_VALIDATOR_ENABLED is false in a production environment
// (see config.InsecureAuthConfig), so a prod container never boots with the
// validator off.
func Auth(cfg AuthConfig) gin.HandlerFunc {
	var keyFunc jwt.Keyfunc
	if cfg.TokenValidatorEnabled {
		jwks, err := keyfunc.NewDefault([]string{cfg.JWKSEndpoint})
		if err != nil {
			panic("auth: failed to initialise JWKS from " + cfg.JWKSEndpoint + ": " + err.Error())
		}
		keyFunc = jwks.Keyfunc
	}

	return func(c *gin.Context) {
		tokenStr := c.GetHeader(jwtAssertionHeader)
		if tokenStr == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing authorization token"})
			return
		}

		info, err := extractUserInfo(tokenStr, cfg, keyFunc)
		if err != nil {
			slog.WarnContext(c.Request.Context(), "auth: token validation failed", "err", err)
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}
		info.RawToken = tokenStr

		ctx := context.WithValue(c.Request.Context(), userInfoKey, info)
		c.Request = c.Request.WithContext(ctx)
		c.Next()
	}
}

// UserInfoFromContext retrieves the authenticated user's info from the context.
// Returns nil if the auth middleware was not applied.
func UserInfoFromContext(ctx context.Context) *UserInfo {
	v, _ := ctx.Value(userInfoKey).(*UserInfo)
	return v
}

// WithUserInfo returns a copy of ctx carrying the given UserInfo.
// Call this in tests to bypass JWT parsing and inject a fake authenticated user.
func WithUserInfo(ctx context.Context, user *UserInfo) context.Context {
	return context.WithValue(ctx, userInfoKey, user)
}

func extractUserInfo(tokenStr string, cfg AuthConfig, keyFunc jwt.Keyfunc) (*UserInfo, error) {
	var c jwtClaims

	if !cfg.TokenValidatorEnabled {
		if _, _, err := new(jwt.Parser).ParseUnverified(tokenStr, &c); err != nil {
			return nil, fmt.Errorf("decode token: %w", err)
		}
	} else {
		token, err := jwt.ParseWithClaims(tokenStr, &c, keyFunc,
			jwt.WithIssuer(cfg.Issuer),
			jwt.WithAudience(cfg.Audience),
			jwt.WithLeeway(cfg.ClockSkew),
			jwt.WithExpirationRequired(),
		)
		if err != nil {
			return nil, fmt.Errorf("validate token: %w", err)
		}
		if !token.Valid {
			return nil, fmt.Errorf("invalid token")
		}
	}

	if c.Email == "" {
		return nil, fmt.Errorf("token missing email claim")
	}
	if c.Subject == "" {
		return nil, fmt.Errorf("token missing sub claim")
	}

	// A missing groups claim is not an error: every route except the
	// admin-gated ones ignores it, and those deny on an empty list anyway.
	return &UserInfo{
		Email:      c.Email,
		UserID:     c.Subject,
		GivenName:  c.GivenName,
		FamilyName: c.FamilyName,
		Groups:     c.Groups,
	}, nil
}
