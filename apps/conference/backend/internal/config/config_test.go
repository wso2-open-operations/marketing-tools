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
	"os"
	"testing"
)

func clearEnv(t *testing.T) {
	t.Helper()
	keys := []string{
		"DB_HOST", "DB_PORT", "DB_USER", "DB_PASSWORD", "DB_NAME", "DB_SCHEMA", "DB_SSLMODE",
		"PORT", "LOG_LEVEL", "APP_ENV",
		"TOKEN_VALIDATOR_ENABLED", "JWKS_ENDPOINT", "JWT_ISSUER", "JWT_AUDIENCE", "RBAC_ADMIN_ROLES",
		"EXCLUDE_EMPLOYEE_COIN_ALLOCATION", "ENABLE_QR_VALIDATIONS", "SESSION_END_TIME_OFFSET_MINUTES", "SESSION_SLOT_MINUTES",
		"QR_PORTAL_ENDPOINT", "QR_PORTAL_TOKEN_URL", "QR_PORTAL_CLIENT_ID", "QR_PORTAL_CLIENT_SECRET",
		"WALLET_ENDPOINT", "WALLET_TOKEN_URL", "WALLET_CLIENT_ID", "WALLET_CLIENT_SECRET",
		"TRANSACTION_ENDPOINT", "TRANSACTION_TOKEN_URL", "TRANSACTION_CLIENT_ID", "TRANSACTION_CLIENT_SECRET",
	}
	for _, k := range keys {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
}

func TestLoad_Defaults(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")

	cfg := Load()

	if cfg.Port != "8080" {
		t.Errorf("expected default Port 8080, got %q", cfg.Port)
	}
	if cfg.DBPort != "5432" {
		t.Errorf("expected default DBPort 5432, got %q", cfg.DBPort)
	}
	if cfg.DBSSLMode != "require" {
		t.Errorf("expected default DBSSLMode require, got %q", cfg.DBSSLMode)
	}
	if cfg.LogLevel != "info" {
		t.Errorf("expected default LogLevel info, got %q", cfg.LogLevel)
	}
	if cfg.ExcludeEmployeeCoinAllocation != true {
		t.Errorf("expected ExcludeEmployeeCoinAllocation default true")
	}
	if cfg.EnableQrValidations != true {
		t.Errorf("expected EnableQrValidations default true")
	}
	if cfg.SessionEndTimeOffsetMinutes != 15 {
		t.Errorf("expected SessionEndTimeOffsetMinutes default 15, got %d", cfg.SessionEndTimeOffsetMinutes)
	}
	if cfg.SessionSlotMinutes != 5 {
		t.Errorf("expected SessionSlotMinutes default 5, got %d", cfg.SessionSlotMinutes)
	}
}

func TestLoad_RBACAdminRolesParsedAsList(t *testing.T) {
	clearEnv(t)
	t.Setenv("RBAC_ADMIN_ROLES", "event-admin-stg, event-admin-prod ,other")

	cfg := Load()

	want := []string{"event-admin-stg", "event-admin-prod", "other"}
	if len(cfg.AdminRoles) != len(want) {
		t.Fatalf("expected %d admin roles, got %d (%v)", len(want), len(cfg.AdminRoles), cfg.AdminRoles)
	}
	for i, w := range want {
		if cfg.AdminRoles[i] != w {
			t.Errorf("AdminRoles[%d] = %q, want %q", i, cfg.AdminRoles[i], w)
		}
	}
}

func TestLoad_BoolFlagsOverridable(t *testing.T) {
	clearEnv(t)
	t.Setenv("EXCLUDE_EMPLOYEE_COIN_ALLOCATION", "false")
	t.Setenv("ENABLE_QR_VALIDATIONS", "false")

	cfg := Load()

	if cfg.ExcludeEmployeeCoinAllocation != false {
		t.Errorf("expected ExcludeEmployeeCoinAllocation false")
	}
	if cfg.EnableQrValidations != false {
		t.Errorf("expected EnableQrValidations false")
	}
}

func TestLoad_ExternalClientConfigs(t *testing.T) {
	clearEnv(t)
	t.Setenv("QR_PORTAL_ENDPOINT", "https://qr.example.com")
	t.Setenv("QR_PORTAL_TOKEN_URL", "https://auth.example.com/token")
	t.Setenv("QR_PORTAL_CLIENT_ID", "qr-id")
	t.Setenv("QR_PORTAL_CLIENT_SECRET", "qr-secret")

	cfg := Load()

	if cfg.QRPortal.Endpoint != "https://qr.example.com" {
		t.Errorf("QRPortal.Endpoint = %q", cfg.QRPortal.Endpoint)
	}
	if cfg.QRPortal.OAuth.TokenURL != "https://auth.example.com/token" {
		t.Errorf("QRPortal.OAuth.TokenURL = %q", cfg.QRPortal.OAuth.TokenURL)
	}
	if cfg.QRPortal.OAuth.ClientID != "qr-id" {
		t.Errorf("QRPortal.OAuth.ClientID = %q", cfg.QRPortal.OAuth.ClientID)
	}
	if cfg.QRPortal.OAuth.ClientSecret != "qr-secret" {
		t.Errorf("QRPortal.OAuth.ClientSecret = %q", cfg.QRPortal.OAuth.ClientSecret)
	}
}

func TestValidate_RequiresCoreDBFields(t *testing.T) {
	clearEnv(t)
	cfg := Load()
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error for missing required fields")
	}
}

func TestValidate_OKWithRequiredFieldsInDevelopment(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")

	cfg := Load()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestValidate_TokenValidatorRequiresJWKSAndIssuer(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")
	t.Setenv("TOKEN_VALIDATOR_ENABLED", "true")

	cfg := Load()
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error when TOKEN_VALIDATOR_ENABLED=true but JWKS_ENDPOINT/JWT_ISSUER/JWT_AUDIENCE missing")
	}
}

func TestDSN_WithAndWithoutPassword(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("DB_SSLMODE", "disable")

	cfg := Load()
	dsn := cfg.DSN()
	if dsn != "host=localhost port=5432 user=administrator dbname=agenda_organizer sslmode=disable options=--search_path=marketingops" {
		t.Errorf("unexpected DSN without password: %q", dsn)
	}

	cfg.DBPassword = "secret"
	dsn = cfg.DSN()
	if dsn != "host=localhost port=5432 user=administrator password=secret dbname=agenda_organizer sslmode=disable options=--search_path=marketingops" {
		t.Errorf("unexpected DSN with password: %q", dsn)
	}
}
