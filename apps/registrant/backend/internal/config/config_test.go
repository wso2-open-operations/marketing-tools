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
	"bytes"
	"errors"
	"testing"
	"time"
)

var testPIIKey = bytes.Repeat([]byte("k"), 32)

func validConfig() Config {
	return Config{
		DBHost:              "localhost",
		DBUser:              "root",
		DBName:              "conference",
		DBSchema:            "marketingops",
		PIIEncryptionKey:    testPIIKey,
		SheetsClientID:      "client-id",
		SheetsRefreshToken:  "refresh-token",
		SheetsTokenURL:      "https://oauth.example.com/token",
		SheetsSpreadsheetID: "sheet-id",
	}
}

func TestValidate_TokenValidatorRequirements(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*Config)
		wantErr string
	}{
		{
			"validator off needs no jwt config",
			func(c *Config) { c.TokenValidatorEnabled = false },
			"",
		},
		{
			"validator on with full jwt config",
			func(c *Config) {
				c.TokenValidatorEnabled = true
				c.JWKSEndpoint = "https://idp.example/jwks"
				c.Issuer = "https://idp.example/token"
				c.Audiences = []string{"client-id"}
			},
			"",
		},
		{
			"validator on without jwks",
			func(c *Config) {
				c.TokenValidatorEnabled = true
				c.Issuer = "https://idp.example/token"
				c.Audiences = []string{"client-id"}
			},
			"JWKS_ENDPOINT is required when TOKEN_VALIDATOR_ENABLED=true",
		},
		{
			"validator on without issuer",
			func(c *Config) {
				c.TokenValidatorEnabled = true
				c.JWKSEndpoint = "https://idp.example/jwks"
				c.Audiences = []string{"client-id"}
			},
			"JWT_ISSUER is required when TOKEN_VALIDATOR_ENABLED=true",
		},
		{
			"validator on without audience",
			func(c *Config) {
				c.TokenValidatorEnabled = true
				c.JWKSEndpoint = "https://idp.example/jwks"
				c.Issuer = "https://idp.example/token"
			},
			"JWT_AUDIENCE is required when TOKEN_VALIDATOR_ENABLED=true",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := validConfig()
			tt.mutate(&c)
			err := c.Validate()
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("Validate() = %v, want nil", err)
				}
				return
			}
			if err == nil || err.Error() != tt.wantErr {
				t.Fatalf("Validate() = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

// TestInsecureAuthConfig pins the predicate cmd/server/main.go exits on: only
// production with the validator off is a refusal to boot.
func TestInsecureAuthConfig(t *testing.T) {
	tests := []struct {
		appEnv    string
		validator bool
		want      bool
	}{
		{"production", false, true},
		{"production", true, false},
		{"development", false, false},
		{"development", true, false},
	}
	for _, tt := range tests {
		c := Config{AppEnv: tt.appEnv, TokenValidatorEnabled: tt.validator}
		if got := c.InsecureAuthConfig(); got != tt.want {
			t.Fatalf("InsecureAuthConfig(appEnv=%q, validator=%v) = %v, want %v",
				tt.appEnv, tt.validator, got, tt.want)
		}
	}
}

func TestParseList(t *testing.T) {
	tests := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"a", []string{"a"}},
		{"a,b", []string{"a", "b"}},
		{" a , b ", []string{"a", "b"}},
		{" , ", []string{}},
	}
	for _, tt := range tests {
		got := parseList(tt.in)
		if len(got) != len(tt.want) {
			t.Fatalf("parseList(%q) = %v, want %v", tt.in, got, tt.want)
		}
		for i := range got {
			if got[i] != tt.want[i] {
				t.Fatalf("parseList(%q) = %v, want %v", tt.in, got, tt.want)
			}
		}
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
		{"missing sheets client id", func(c *Config) { c.SheetsClientID = "" }, "SHEETS_CLIENT_ID is required"},
		{"missing sheets refresh token", func(c *Config) { c.SheetsRefreshToken = "" }, "SHEETS_REFRESH_TOKEN is required"},
		{"missing sheets token url", func(c *Config) { c.SheetsTokenURL = "" }, "SHEETS_TOKEN_URL is required"},
		{"missing spreadsheet id", func(c *Config) { c.SheetsSpreadsheetID = "" }, "SHEETS_SPREADSHEET_ID is required"},
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
