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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const jwtAssertionHeader = "x-jwt-assertion"

type contextKey string

const userInfoKey contextKey = "user-info"

// UserInfo holds the invoker identity extracted from the x-jwt-assertion
// header's payload.
type UserInfo struct {
	Email string `json:"email"`
}

// JwtInterceptor mirrors the Ballerina JwtInterceptor: it decodes the
// x-jwt-assertion header's JWT payload (without verifying the signature,
// matching the original service's trust model — the gateway in front of
// this service is assumed to have already validated the token) and stores
// the extracted UserInfo in the request context for downstream handlers.
func JwtInterceptor() gin.HandlerFunc {
	return func(c *gin.Context) {
		idToken := c.GetHeader(jwtAssertionHeader)
		if idToken == "" {
			msg := "Missing invoker info header!"
			slog.ErrorContext(c.Request.Context(), msg)
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"message": msg})
			return
		}

		payload, err := decodeJWTPayload(idToken)
		if err != nil {
			msg := "Error while reading the Invoker info!"
			slog.ErrorContext(c.Request.Context(), msg, "error", err)
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"message": msg})
			return
		}

		var userInfo UserInfo
		if err := json.Unmarshal(payload, &userInfo); err != nil {
			msg := "Malformed Invoker info object!"
			slog.ErrorContext(c.Request.Context(), msg, "error", err)
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"message": msg})
			return
		}
		if userInfo.Email == "" {
			msg := "Invoker info missing email!"
			slog.ErrorContext(c.Request.Context(), msg)
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"message": msg})
			return
		}

		ctx := context.WithValue(c.Request.Context(), userInfoKey, &userInfo)
		c.Request = c.Request.WithContext(ctx)
		c.Next()
	}
}

// decodeJWTPayload extracts and base64url-decodes the payload segment of a
// JWT, without verifying its signature.
func decodeJWTPayload(token string) ([]byte, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("invalid JWT format: expected 3 segments, got %d", len(parts))
	}
	return base64.RawURLEncoding.DecodeString(parts[1])
}

// UserInfoFromContext retrieves the invoker's UserInfo from the context.
// Returns nil if JwtInterceptor was not applied.
func UserInfoFromContext(ctx context.Context) *UserInfo {
	v, _ := ctx.Value(userInfoKey).(*UserInfo)
	return v
}

// WithUserInfo returns a copy of ctx carrying the given UserInfo. Call this
// in tests to bypass JWT parsing and inject a fake invoker.
func WithUserInfo(ctx context.Context, user *UserInfo) context.Context {
	return context.WithValue(ctx, userInfoKey, user)
}
