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
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func unverifiedToken(t *testing.T, claims jwtClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	s, err := tok.SignedString([]byte("test-signing-key-unused-by-unverified-parser"))
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return s
}

func newRouter(cfg AuthConfig) *gin.Engine {
	r := gin.New()
	r.Use(Auth(cfg))
	r.GET("/ping", func(c *gin.Context) {
		c.Status(http.StatusOK)
	})
	return r
}

func TestAuth_MissingHeader_Returns401(t *testing.T) {
	r := newRouter(AuthConfig{})
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestAuth_UnverifiedMode_DecodesValidToken(t *testing.T) {
	r := gin.New()
	r.Use(Auth(AuthConfig{TokenValidatorEnabled: false}))

	var got *UserInfo
	r.GET("/ping", func(c *gin.Context) {
		got = UserInfoFromContext(c.Request.Context())
		c.Status(http.StatusOK)
	})

	claims := jwtClaims{
		Email: "attendee@example.com",
		RegisteredClaims: jwt.RegisteredClaims{
			Subject: "user-uuid-123",
		},
	}
	token := unverifiedToken(t, claims)

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set(jwtAssertionHeader, token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if got == nil {
		t.Fatal("expected UserInfo to be set in context")
	}
	if got.Email != "attendee@example.com" {
		t.Errorf("Email = %q, want attendee@example.com", got.Email)
	}
	if got.UserID != "user-uuid-123" {
		t.Errorf("UserID = %q, want user-uuid-123", got.UserID)
	}
	if got.RawToken != token {
		t.Errorf("RawToken = %q, want the literal incoming header value %q", got.RawToken, token)
	}
}

func TestAuth_UnverifiedMode_MissingEmailClaim_Returns401(t *testing.T) {
	r := newRouter(AuthConfig{TokenValidatorEnabled: false})
	claims := jwtClaims{
		RegisteredClaims: jwt.RegisteredClaims{Subject: "user-uuid-123"},
	}
	token := unverifiedToken(t, claims)

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set(jwtAssertionHeader, token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing email claim, got %d", w.Code)
	}
}

func TestAuth_UnverifiedMode_MissingSubClaim_Returns401(t *testing.T) {
	r := newRouter(AuthConfig{TokenValidatorEnabled: false})
	claims := jwtClaims{Email: "attendee@example.com"}
	token := unverifiedToken(t, claims)

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set(jwtAssertionHeader, token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing sub claim, got %d", w.Code)
	}
}

func TestAuth_UnverifiedMode_MalformedToken_Returns401(t *testing.T) {
	r := newRouter(AuthConfig{TokenValidatorEnabled: false})

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set(jwtAssertionHeader, "not-a-jwt")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for malformed token, got %d", w.Code)
	}
}
