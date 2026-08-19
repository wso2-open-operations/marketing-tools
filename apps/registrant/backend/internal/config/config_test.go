// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package config

import (
	"bytes"
	"errors"
	"testing"
	"time"
)

var testPIIKey = bytes.Repeat([]byte("k"), 32)

func validConfig() Config {
	return Config{
		DBHost:               "localhost",
		DBUser:               "root",
		DBName:               "conference",
		DBSchema:             "marketingops",
		PIIEncryptionKey:     testPIIKey,
		EmailServiceEndpoint: "https://email.example.com",
		EmailFrom:            "noreply@example.com",
		SheetsSpreadsheetID:  "sheet-id",
		AuthorizedRole:       "admin-role",
	}
}

func TestValidate_MissingFields(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(c *Config)
		wantErr string
	}{
		{"missing db host", func(c *Config) { c.DBHost = "" }, "DB_HOST is required"},
		{"missing db user", func(c *Config) { c.DBUser = "" }, "DB_USER is required"},
		{"missing db name", func(c *Config) { c.DBName = "" }, "DB_NAME is required"},
		{"missing db schema", func(c *Config) { c.DBSchema = "" }, "DB_SCHEMA is required"},
		{
			"missing pii key",
			func(c *Config) { c.PIIEncryptionKey = nil },
			"PII_ENCRYPTION_KEY is required and must decode to exactly 32 bytes",
		},
		{
			"short pii key",
			func(c *Config) { c.PIIEncryptionKey = []byte("too-short") },
			"PII_ENCRYPTION_KEY is required and must decode to exactly 32 bytes",
		},
		{"missing email endpoint", func(c *Config) { c.EmailServiceEndpoint = "" }, "EMAIL_SERVICE_ENDPOINT is required"},
		{"missing email from", func(c *Config) { c.EmailFrom = "" }, "EMAIL_FROM is required"},
		{"missing spreadsheet id", func(c *Config) { c.SheetsSpreadsheetID = "" }, "SHEETS_SPREADSHEET_ID is required"},
		{"missing authorized role", func(c *Config) { c.AuthorizedRole = "" }, "AUTHORIZED_ROLE is required"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := validConfig()
			tt.mutate(&c)
			err := c.Validate()
			if err == nil || err.Error() != tt.wantErr {
				t.Fatalf("Validate() error = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

func TestValidate_BadKeyBase64(t *testing.T) {
	c := validConfig()
	c.piiKeyDecodeErr = errors.New("bad base64")
	if err := c.Validate(); err == nil {
		t.Fatal("Validate() expected error for bad base64 key, got nil")
	}
}

func TestValidate_OK(t *testing.T) {
	if err := validConfig().Validate(); err != nil {
		t.Fatalf("Validate() unexpected error: %v", err)
	}
}

func TestDSN(t *testing.T) {
	c := Config{
		DBUser: "root", DBHost: "localhost", DBPort: "5432",
		DBName: "agenda_organizer", DBSchema: "marketingops", DBSSLMode: "disable",
	}
	want := "host=localhost port=5432 user=root dbname=agenda_organizer sslmode=disable options=--search_path=marketingops"
	if got := c.DSN(); got != want {
		t.Fatalf("DSN() without password = %q, want %q", got, want)
	}

	c.DBPassword = "secret"
	want = "host=localhost port=5432 user=root password=secret dbname=agenda_organizer sslmode=disable options=--search_path=marketingops"
	if got := c.DSN(); got != want {
		t.Fatalf("DSN() with password = %q, want %q", got, want)
	}
}

func TestLoad_Defaults(t *testing.T) {
	t.Setenv("PORT", "")
	t.Setenv("DB_PORT", "")
	t.Setenv("DB_SSLMODE", "")
	t.Setenv("LOG_LEVEL", "")
	t.Setenv("APP_ENV", "")
	t.Setenv("DB_MAX_OPEN_CONNS", "")
	t.Setenv("DB_MAX_CONN_LIFETIME_SECONDS", "")
	t.Setenv("DB_MAX_IDLE_CONNS", "")

	c := Load()
	if c.Port != "8080" {
		t.Errorf("Port default = %q, want 8080", c.Port)
	}
	if c.DBPort != "5432" {
		t.Errorf("DBPort default = %q, want 5432", c.DBPort)
	}
	if c.DBSSLMode != "require" {
		t.Errorf("DBSSLMode default = %q, want require", c.DBSSLMode)
	}
	if c.LogLevel != "info" {
		t.Errorf("LogLevel default = %q, want info", c.LogLevel)
	}
	if c.AppEnv != "production" {
		t.Errorf("AppEnv default = %q, want production", c.AppEnv)
	}
	if c.DBMaxOpenConns != 10 {
		t.Errorf("DBMaxOpenConns default = %d, want 10", c.DBMaxOpenConns)
	}
	if c.DBMaxConnLifetimeSeconds != 100.0 {
		t.Errorf("DBMaxConnLifetimeSeconds default = %v, want 100.0", c.DBMaxConnLifetimeSeconds)
	}
	if c.DBMaxIdleConns != 5 {
		t.Errorf("DBMaxIdleConns default = %d, want 5", c.DBMaxIdleConns)
	}
	if got, want := c.ConnMaxLifetime(), 100*time.Second; got != want {
		t.Errorf("ConnMaxLifetime() = %v, want %v", got, want)
	}
}
