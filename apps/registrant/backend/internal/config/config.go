// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port     string
	LogLevel string
	AppEnv   string

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

	// Email service
	EmailServiceEndpoint   string
	EmailFrom              string
	EmailOAuthTokenURL     string
	EmailOAuthClientID     string
	EmailOAuthClientSecret string

	// Google Sheets
	SheetsClientID              string
	SheetsClientSecret          string
	SheetsRefreshToken          string
	SheetsTokenURL              string
	SheetsSpreadsheetID         string
	SheetsSheetID               int
	SheetsSheetName             string
	SheetsURL                   string
	SheetsRegistrationSheetName string
	SheetsRegistrationSheetID   int

	// AuthorizedRole mirrors authorization.bal's `configurable string
	// authorizedRole = ?;` from the original Ballerina service. It was never
	// read anywhere in that service's interceptor logic — kept here,
	// unused, for parity rather than ported as dead code.
	AuthorizedRole string
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

	// Decoded best-effort here; Validate() is where a missing/malformed key
	// is actually rejected, matching this file's existing Load()-is-tolerant,
	// Validate()-is-strict split.
	piiEncryptionKey, piiKeyDecodeErr := base64.StdEncoding.DecodeString(os.Getenv("PII_ENCRYPTION_KEY"))

	return Config{
		Port:     port,
		LogLevel: logLevel,
		AppEnv:   appEnv,

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

		EmailServiceEndpoint:   os.Getenv("EMAIL_SERVICE_ENDPOINT"),
		EmailFrom:              os.Getenv("EMAIL_FROM"),
		EmailOAuthTokenURL:     os.Getenv("EMAIL_OAUTH_TOKEN_URL"),
		EmailOAuthClientID:     os.Getenv("EMAIL_OAUTH_CLIENT_ID"),
		EmailOAuthClientSecret: os.Getenv("EMAIL_OAUTH_CLIENT_SECRET"),

		SheetsClientID:              os.Getenv("SHEETS_CLIENT_ID"),
		SheetsClientSecret:          os.Getenv("SHEETS_CLIENT_SECRET"),
		SheetsRefreshToken:          os.Getenv("SHEETS_REFRESH_TOKEN"),
		SheetsTokenURL:              os.Getenv("SHEETS_TOKEN_URL"),
		SheetsSpreadsheetID:         os.Getenv("SHEETS_SPREADSHEET_ID"),
		SheetsSheetID:               getEnvInt("SHEETS_SHEET_ID", 0),
		SheetsSheetName:             os.Getenv("SHEETS_SHEET_NAME"),
		SheetsURL:                   os.Getenv("SHEETS_URL"),
		SheetsRegistrationSheetName: os.Getenv("SHEETS_REGISTRATION_SHEET_NAME"),
		SheetsRegistrationSheetID:   getEnvInt("SHEETS_REGISTRATION_SHEET_ID", 0),

		AuthorizedRole: os.Getenv("AUTHORIZED_ROLE"),
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
	if c.EmailServiceEndpoint == "" {
		return errors.New("EMAIL_SERVICE_ENDPOINT is required")
	}
	if c.EmailFrom == "" {
		return errors.New("EMAIL_FROM is required")
	}
	if c.SheetsSpreadsheetID == "" {
		return errors.New("SHEETS_SPREADSHEET_ID is required")
	}
	if c.AuthorizedRole == "" {
		return errors.New("AUTHORIZED_ROLE is required")
	}
	return nil
}
