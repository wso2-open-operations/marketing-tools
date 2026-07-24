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
	"strings"
	"testing"
	"time"
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
		"PII_ENCRYPTION_KEY",
		"AI_MATCHMAKING_SERVICE_URL", "AI_PERSONALIZE_AGENT_SERVICE_URL", "AI_PICKED_FOR_YOU_SERVICE_URL", "AI_CHAT_SERVICE_URL",
		"AI_REQUEST_TIMEOUT_SECONDS",
		"AI_ENABLED_CHAT_ASSISTANT", "AI_ENABLED_PERSONALIZED_AGENDA", "AI_ENABLED_MATCH_MAKER", "AI_ENABLED_O2_BAR",
		"VENUE_TIMEZONE",
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

func TestLoad_VenueTimezoneDefaultsToUTC(t *testing.T) {
	clearEnv(t)

	cfg := Load()

	if cfg.VenueTimezone != "UTC" {
		t.Errorf("expected default VenueTimezone UTC, got %q", cfg.VenueTimezone)
	}
	if cfg.VenueLocation == nil {
		t.Fatal("expected VenueLocation to be non-nil")
	}
	if _, offset := time.Now().In(cfg.VenueLocation).Zone(); offset != 0 {
		t.Errorf("expected UTC offset 0, got %d", offset)
	}
}

func TestLoad_VenueTimezoneFromEnv(t *testing.T) {
	clearEnv(t)
	t.Setenv("VENUE_TIMEZONE", "Asia/Colombo")

	cfg := Load()

	if cfg.VenueTimezone != "Asia/Colombo" {
		t.Errorf("VenueTimezone = %q, want Asia/Colombo", cfg.VenueTimezone)
	}
	if cfg.VenueLocation == nil {
		t.Fatal("expected VenueLocation to be non-nil")
	}
	// Asia/Colombo is a fixed +05:30 (no DST): 5*3600 + 30*60 = 19800s.
	if _, offset := time.Date(2026, 7, 1, 0, 0, 0, 0, cfg.VenueLocation).Zone(); offset != 19800 {
		t.Errorf("Asia/Colombo offset = %d, want 19800", offset)
	}
}

func TestValidate_RejectsInvalidVenueTimezone(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")
	t.Setenv("PII_ENCRYPTION_KEY", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
	t.Setenv("VENUE_TIMEZONE", "Not/ARealZone")

	cfg := Load()
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for an unloadable VENUE_TIMEZONE")
	}
	if !strings.Contains(err.Error(), "VENUE_TIMEZONE") {
		t.Errorf("error = %q, want it to mention VENUE_TIMEZONE", err.Error())
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

func TestLoad_AIAgentDefaults(t *testing.T) {
	clearEnv(t)

	cfg := Load()

	if cfg.AIAgent.MatchmakingServiceURL != "" || cfg.AIAgent.PersonalizeAgentServiceURL != "" ||
		cfg.AIAgent.PickedForYouServiceURL != "" || cfg.AIAgent.ChatServiceURL != "" {
		t.Errorf("expected empty AIAgent service URLs by default, got %+v", cfg.AIAgent)
	}
	if cfg.AIAgent.RequestTimeout != 120*time.Second {
		t.Errorf("expected default AIAgent.RequestTimeout 120s, got %v", cfg.AIAgent.RequestTimeout)
	}
	if cfg.AIFeatureStatus.EnabledChatAssistant || cfg.AIFeatureStatus.EnabledPersonalizedAgenda ||
		cfg.AIFeatureStatus.EnabledMatchMaker || cfg.AIFeatureStatus.EnabledO2Bar {
		t.Errorf("expected every AIFeatureStatus flag to default to false, got %+v", cfg.AIFeatureStatus)
	}
}

func TestLoad_AIAgentConfigFromEnv(t *testing.T) {
	clearEnv(t)
	t.Setenv("AI_MATCHMAKING_SERVICE_URL", "https://matchmaking.example.com")
	t.Setenv("AI_PERSONALIZE_AGENT_SERVICE_URL", "https://personalize.example.com")
	t.Setenv("AI_PICKED_FOR_YOU_SERVICE_URL", "https://pickedforyou.example.com")
	t.Setenv("AI_CHAT_SERVICE_URL", "https://chat.example.com")
	t.Setenv("AI_REQUEST_TIMEOUT_SECONDS", "30")
	t.Setenv("AI_ENABLED_CHAT_ASSISTANT", "true")
	t.Setenv("AI_ENABLED_PERSONALIZED_AGENDA", "true")
	t.Setenv("AI_ENABLED_MATCH_MAKER", "true")
	t.Setenv("AI_ENABLED_O2_BAR", "true")

	cfg := Load()

	if cfg.AIAgent.MatchmakingServiceURL != "https://matchmaking.example.com" {
		t.Errorf("MatchmakingServiceURL = %q", cfg.AIAgent.MatchmakingServiceURL)
	}
	if cfg.AIAgent.PersonalizeAgentServiceURL != "https://personalize.example.com" {
		t.Errorf("PersonalizeAgentServiceURL = %q", cfg.AIAgent.PersonalizeAgentServiceURL)
	}
	if cfg.AIAgent.PickedForYouServiceURL != "https://pickedforyou.example.com" {
		t.Errorf("PickedForYouServiceURL = %q", cfg.AIAgent.PickedForYouServiceURL)
	}
	if cfg.AIAgent.ChatServiceURL != "https://chat.example.com" {
		t.Errorf("ChatServiceURL = %q", cfg.AIAgent.ChatServiceURL)
	}
	if cfg.AIAgent.RequestTimeout != 30*time.Second {
		t.Errorf("RequestTimeout = %v, want 30s", cfg.AIAgent.RequestTimeout)
	}
	if !cfg.AIFeatureStatus.EnabledChatAssistant || !cfg.AIFeatureStatus.EnabledPersonalizedAgenda ||
		!cfg.AIFeatureStatus.EnabledMatchMaker || !cfg.AIFeatureStatus.EnabledO2Bar {
		t.Errorf("expected every AIFeatureStatus flag true, got %+v", cfg.AIFeatureStatus)
	}
}

func TestValidate_DoesNotRequireAIAgentFields(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")
	t.Setenv("PII_ENCRYPTION_KEY", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

	cfg := Load()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected no error with blank AIAgent config, got %v", err)
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
	t.Setenv("PII_ENCRYPTION_KEY", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

	cfg := Load()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestLoad_PIIEncryptionKeyDecodedFromBase64(t *testing.T) {
	clearEnv(t)
	t.Setenv("PII_ENCRYPTION_KEY", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")

	cfg := Load()
	if len(cfg.PIIEncryptionKey) != 32 {
		t.Fatalf("expected 32-byte decoded key, got %d bytes", len(cfg.PIIEncryptionKey))
	}
}

func TestValidate_RequiresPIIEncryptionKey(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")

	cfg := Load()
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error when PII_ENCRYPTION_KEY is missing")
	}
}

func TestValidate_RejectsMalformedPIIEncryptionKey(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")
	t.Setenv("PII_ENCRYPTION_KEY", "dG9vLXNob3J0") // base64("too-short"), not 32 bytes

	cfg := Load()
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected error for a PII_ENCRYPTION_KEY that doesn't decode to 32 bytes")
	}
}

func TestValidate_RejectsInvalidBase64PIIEncryptionKey(t *testing.T) {
	clearEnv(t)
	t.Setenv("DB_HOST", "localhost")
	t.Setenv("DB_USER", "administrator")
	t.Setenv("DB_NAME", "agenda_organizer")
	t.Setenv("DB_SCHEMA", "marketingops")
	t.Setenv("APP_ENV", "development")
	t.Setenv("PII_ENCRYPTION_KEY", "not-valid-base64!!!")

	cfg := Load()
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for invalid base64 PII_ENCRYPTION_KEY")
	}
	if !strings.Contains(err.Error(), "invalid base64") {
		t.Errorf("error = %q, want it to mention invalid base64", err.Error())
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
