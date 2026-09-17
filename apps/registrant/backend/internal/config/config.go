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

package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port     string
	LogLevel string
	AppEnv   string

	// JWT / auth. Same four variables, same names and same semantics as
	// apps/conference/backend, so both services are pointed at one set of
	// Asgardeo values.
	JWKSEndpoint string
	Issuer       string
	// Audiences is the set of `aud` values the token validator accepts, read
	// from JWT_AUDIENCE as a comma-separated list. A token is accepted when
	// its aud claim names AT LEAST ONE of these (see middleware.AuthConfig),
	// not all of them: more than one Asgardeo application can reach this
	// service -- the registrant microapp directly, and the conference
	// backend's /registrant reverse proxy -- and each mints tokens carrying
	// its own client id as the audience. A single value keeps working exactly
	// as one would expect: a one-element list is the old equality check.
	Audiences []string
	// TokenValidatorEnabled turns on signature/issuer/audience/expiry
	// verification. Defaults to false so dev and tests keep working with
	// hand-made tokens; production cannot boot without it (see
	// InsecureAuthConfig, enforced in cmd/server/main.go).
	TokenValidatorEnabled bool

	// Database (Postgres, shared agenda_organizer/marketingops schema with
	// apps/conference/backend)
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	DBSchema   string
	DBSSLMode  string

	// PIIEncryptionKey encrypts/decrypts attendee_id in attendee_registration
	// (AES-256-GCM, see internal/crypto). Decoded from the base64
	// PII_ENCRYPTION_KEY env var; must be exactly 32 bytes once decoded, and
	// must match the value apps/conference/backend is configured with, since
	// its IsRegistered check decrypts rows this service writes.
	PIIEncryptionKey []byte
	// piiKeyDecodeErr holds a base64 decode failure from Load(), so
	// Validate() can report the actual problem instead of a misleading
	// length mismatch.
	piiKeyDecodeErr error

	// DB connection pool, mirroring the original Ballerina service's
	// sql:ConnectionPool config. Defaults match that service's actual
	// production values (maxOpenConnections=10, maxConnectionLifeTime=100s,
	// minIdleConnections=5).
	DBMaxOpenConns           int
	DBMaxConnLifetimeSeconds float64
	DBMaxIdleConns           int

	// Google Sheets
	SheetsClientID      string
	SheetsClientSecret  string
	SheetsRefreshToken  string
	SheetsTokenURL      string
	SheetsSpreadsheetID string
	SheetsSheetID       int
	SheetsSheetName     string
	SheetsURL           string
}

func Load() Config {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	dbPort := os.Getenv("DB_PORT")
	if dbPort == "" {
		dbPort = "5432"
	}
	dbSSLMode := os.Getenv("DB_SSLMODE")
	if dbSSLMode == "" {
		dbSSLMode = "require"
	}
	logLevel := os.Getenv("LOG_LEVEL")
	if logLevel == "" {
		logLevel = "info"
	}
	appEnv := os.Getenv("APP_ENV")
	if appEnv == "" {
		appEnv = "production"
	}
	tokenValidatorEnabled := boolWithDefault("TOKEN_VALIDATOR_ENABLED", false)

	// Decoded best-effort here; Validate() is where a missing/malformed key
	// is actually rejected, matching this file's existing Load()-is-tolerant,
	// Validate()-is-strict split.
	piiEncryptionKey, piiKeyDecodeErr := base64.StdEncoding.DecodeString(os.Getenv("PII_ENCRYPTION_KEY"))

	return Config{
		Port:     port,
		LogLevel: logLevel,
		AppEnv:   appEnv,

		JWKSEndpoint:          os.Getenv("JWKS_ENDPOINT"),
		Issuer:                os.Getenv("JWT_ISSUER"),
		Audiences:             parseList(os.Getenv("JWT_AUDIENCE")),
		TokenValidatorEnabled: tokenValidatorEnabled,

		DBHost:     os.Getenv("DB_HOST"),
		DBPort:     dbPort,
		DBUser:     os.Getenv("DB_USER"),
		DBPassword: os.Getenv("DB_PASSWORD"),
		DBName:     os.Getenv("DB_NAME"),
		DBSchema:   os.Getenv("DB_SCHEMA"),
		DBSSLMode:  dbSSLMode,

		PIIEncryptionKey: piiEncryptionKey,
		piiKeyDecodeErr:  piiKeyDecodeErr,

		DBMaxOpenConns:           getEnvInt("DB_MAX_OPEN_CONNS", 10),
		DBMaxConnLifetimeSeconds: getEnvFloat("DB_MAX_CONN_LIFETIME_SECONDS", 100.0),
		DBMaxIdleConns:           getEnvInt("DB_MAX_IDLE_CONNS", 5),

		SheetsClientID:      os.Getenv("SHEETS_CLIENT_ID"),
		SheetsClientSecret:  os.Getenv("SHEETS_CLIENT_SECRET"),
		SheetsRefreshToken:  os.Getenv("SHEETS_REFRESH_TOKEN"),
		SheetsTokenURL:      os.Getenv("SHEETS_TOKEN_URL"),
		SheetsSpreadsheetID: os.Getenv("SHEETS_SPREADSHEET_ID"),
		SheetsSheetID:       getEnvInt("SHEETS_SHEET_ID", 0),
		SheetsSheetName:     os.Getenv("SHEETS_SHEET_NAME"),
		SheetsURL:           os.Getenv("SHEETS_URL"),
	}
}

func getEnvInt(key string, def int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return v
}

func boolWithDefault(key string, def bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	parsed, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return parsed
}

// parseList splits a comma-separated env var, trimming blanks. A value that is
// nothing but separators and spaces yields an empty list rather than a list of
// empty strings -- which would look configured and match nothing.
func parseList(v string) []string {
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func getEnvFloat(key string, def float64) float64 {
	raw := os.Getenv(key)
	if raw == "" {
		return def
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return def
	}
	return v
}

// ConnMaxLifetime converts DBMaxConnLifetimeSeconds (matching the original
// service's decimal-seconds config) into a time.Duration for database/sql.
func (c Config) ConnMaxLifetime() time.Duration {
	return time.Duration(c.DBMaxConnLifetimeSeconds * float64(time.Second))
}

// DSN assembles a libpq keyword=value connection string from individual
// vars, matching apps/conference/backend's format for the same shared
// database. The keyword=value format avoids URL-encoding issues with
// special characters in passwords.
func (c Config) DSN() string {
	if c.DBPassword != "" {
		return fmt.Sprintf(
			"host=%s port=%s user=%s password=%s dbname=%s sslmode=%s options=--search_path=%s",
			c.DBHost, c.DBPort, c.DBUser, c.DBPassword, c.DBName, c.DBSSLMode, c.DBSchema,
		)
	}
	return fmt.Sprintf(
		"host=%s port=%s user=%s dbname=%s sslmode=%s options=--search_path=%s",
		c.DBHost, c.DBPort, c.DBUser, c.DBName, c.DBSSLMode, c.DBSchema,
	)
}

func (c Config) Validate() error {
	if c.DBHost == "" {
		return errors.New("DB_HOST is required")
	}
	if c.DBUser == "" {
		return errors.New("DB_USER is required")
	}
	if c.DBName == "" {
		return errors.New("DB_NAME is required")
	}
	if c.DBSchema == "" {
		return errors.New("DB_SCHEMA is required")
	}
	if c.piiKeyDecodeErr != nil {
		return fmt.Errorf("PII_ENCRYPTION_KEY: invalid base64: %w", c.piiKeyDecodeErr)
	}
	if len(c.PIIEncryptionKey) != 32 {
		return errors.New("PII_ENCRYPTION_KEY is required and must decode to exactly 32 bytes")
	}
	if c.SheetsClientID == "" {
		return errors.New("SHEETS_CLIENT_ID is required")
	}
	if c.SheetsRefreshToken == "" {
		return errors.New("SHEETS_REFRESH_TOKEN is required")
	}
	if c.SheetsTokenURL == "" {
		return errors.New("SHEETS_TOKEN_URL is required")
	}
	if c.SheetsSpreadsheetID == "" {
		return errors.New("SHEETS_SPREADSHEET_ID is required")
	}
	// When the token validator is on, JWKS/issuer/audience are all required --
	// signature verification and the iss/aud checks cannot run without them. In
	// production this chain is not optional: main.go fails closed on
	// InsecureAuthConfig(), so a production deployment is forced to set
	// TOKEN_VALIDATOR_ENABLED=true to boot, and reaching that state forces these
	// three to be set here as well. Dev/test keep the validator off by default
	// and skip this block.
	if c.TokenValidatorEnabled {
		if c.JWKSEndpoint == "" {
			return errors.New("JWKS_ENDPOINT is required when TOKEN_VALIDATOR_ENABLED=true")
		}
		if c.Issuer == "" {
			return errors.New("JWT_ISSUER is required when TOKEN_VALIDATOR_ENABLED=true")
		}
		if len(c.Audiences) == 0 {
			return errors.New("JWT_AUDIENCE is required when TOKEN_VALIDATOR_ENABLED=true")
		}
	}
	return nil
}

// InsecureAuthConfig reports a production deployment running with JWT signature
// validation switched off, which accepts forged and expired tokens.
//
// TOKEN_VALIDATOR_ENABLED still defaults to false on purpose: flipping the
// global default would break dev/test, which rely on it being off. The
// AppEnv=="production" gate here is what enforces prod -- main.go FAILS CLOSED
// on this predicate, so a production container refuses to boot with signature
// validation off. Deliberately not a Validate() failure: Validate() has no view
// of "is this prod" beyond AppEnv, and keeping the refusal in main.go keeps the
// fail-closed decision in one place. Mirrors the identically-named predicate in
// apps/conference/backend.
func (c Config) InsecureAuthConfig() bool {
	return c.AppEnv == "production" && !c.TokenValidatorEnabled
}
