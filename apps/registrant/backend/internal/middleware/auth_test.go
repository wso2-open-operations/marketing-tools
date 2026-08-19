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
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func fakeJWT(payloadJSON string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(payloadJSON))
	return header + "." + payload + ".signature"
}

func runInterceptor(req *http.Request) (*httptest.ResponseRecorder, *UserInfo) {
	w := httptest.NewRecorder()
	r := gin.New()
	var captured *UserInfo
	r.GET("/", JwtInterceptor(), func(c *gin.Context) {
		captured = UserInfoFromContext(c.Request.Context())
		c.Status(http.StatusOK)
	})
	r.ServeHTTP(w, req)
	return w, captured
}

func TestJwtInterceptor_MissingHeader(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w, captured := runInterceptor(req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
	if captured != nil {
		t.Fatalf("expected handler not to run, got captured user info")
	}
}

func TestJwtInterceptor_MalformedToken(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, "not-a-jwt")
	w, _ := runInterceptor(req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestJwtInterceptor_InvalidBase64Payload(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, "header.not!valid!base64.signature")
	w, _ := runInterceptor(req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestJwtInterceptor_InvalidJSONPayload(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, fakeJWT("not json"))
	w, _ := runInterceptor(req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestJwtInterceptor_MissingEmail(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, fakeJWT(`{"other":"ignored"}`))
	w, captured := runInterceptor(req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
	if captured != nil {
		t.Fatalf("expected handler not to run, got captured user info")
	}
}

func TestJwtInterceptor_ValidToken(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(jwtAssertionHeader, fakeJWT(`{"email":"attendee@wso2.com","other":"ignored"}`))
	w, captured := runInterceptor(req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	if captured == nil {
		t.Fatal("expected user info to be captured")
	}
	if captured.Email != "attendee@wso2.com" {
		t.Fatalf("Email = %q, want %q", captured.Email, "attendee@wso2.com")
	}
}

func TestWithUserInfo(t *testing.T) {
	ctx := WithUserInfo(httptest.NewRequest(http.MethodGet, "/", nil).Context(), &UserInfo{Email: "test@example.com"})
	got := UserInfoFromContext(ctx)
	if got == nil || got.Email != "test@example.com" {
		t.Fatalf("UserInfoFromContext() = %+v, want Email=test@example.com", got)
	}
}
