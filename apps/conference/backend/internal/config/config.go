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

// OAuthClientConfig holds OAuth2 client-credentials settings for an external service.
type OAuthClientConfig struct {
	TokenURL     string
	ClientID     string
	ClientSecret string
}

// ExternalServiceConfig holds the base endpoint and OAuth2 credentials for an
// external service integration (QR portal, wallet, transaction/blockchain).
type ExternalServiceConfig struct {
	Endpoint string
	OAuth    OAuthClientConfig
}

// AIAgentConfig holds the base URLs for the external AI agent services
// (matchmaking, personalize, picked-for-you, chat) and the shared request
// timeout applied to all of them. Deliberately no OAuth sub-struct: unlike
// QRPortal/Wallet/Transaction, nothing in the AI agent integration uses
// OAuth2 -- auth is pure pass-through of the caller's own JWT (see
// .claude/PLAN.md).
type AIAgentConfig struct {
	MatchmakingServiceURL      string
	PersonalizeAgentServiceURL string
	PickedForYouServiceURL     string
	ChatServiceURL             string
	RequestTimeout             time.Duration
}

// AIFeatureStatus mirrors the old Ballerina AiFeatureStatus configurable --
// each flag defaults to false ("everything disabled") since that's the safe
// default for a port, unlike the old service which required all 4 configured.
type AIFeatureStatus struct {
	EnabledChatAssistant      bool
	EnabledPersonalizedAgenda bool
	EnabledMatchMaker         bool
	EnabledO2Bar              bool
}

type Config struct {
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	DBSchema   string
	DBSSLMode  string
	Port       string
	LogLevel   string
	AppEnv     string

	// JWT / auth
	JWKSEndpoint          string
	Issuer                string
	Audience              string
	TokenValidatorEnabled bool
	AdminRoles            []string

	// WSO2 Coin / O2C feature flags
	ExcludeEmployeeCoinAllocation bool
	EnableQrValidations           bool
	SessionEndTimeOffsetMinutes   int
	// SessionSlotMinutes converts a session's slot_index/duration_slots into
	// wall-clock time relative to its day's start_minute. There is no
	// authoritative constant for this in the schema; 5 matches every session
	// in the current marketingops data (e.g. a 60-minute Registration block
	// stored as duration_slots=12). Override via env if the data ever assumes
	// a different slot size.
	SessionSlotMinutes int

	// VenueTimezone is the IANA name of the conference venue's timezone
	// (VENUE_TIMEZONE env, default "UTC"). Session times are stored as a
	// day date + slot offset with no zone in the shared schema, so the wall
	// clock has to be anchored to a zone somewhere; this is that anchor until
	// conference_config gains a real venue_timezone column upstream. It's also
	// surfaced verbatim in the event/agenda payloads so the frontend stops
	// hardcoding its own REACT_APP_TIMEZONE.
	VenueTimezone string
	// VenueLocation is VenueTimezone parsed via time.LoadLocation. nil only
	// when parsing failed, in which case venueTZLoadErr is set and Validate()
	// rejects the config.
	VenueLocation  *time.Location
	venueTZLoadErr error

	// PIIEncryptionKey decrypts PII fields (e.g. speaker name/title/bio) that
	// are encrypted at rest in the shared marketingops schema. Decoded from
	// the base64 PII_ENCRYPTION_KEY env var; must be exactly 32 bytes
	// (AES-256) once decoded.
	PIIEncryptionKey []byte
	// piiKeyDecodeErr holds a base64 decode failure from Load(), so Validate()
	// can report the actual problem instead of a misleading length mismatch.
	piiKeyDecodeErr error

	// External integrations
	QRPortal    ExternalServiceConfig
	Wallet      ExternalServiceConfig
	Transaction ExternalServiceConfig

	// AI Features
	AIAgent         AIAgentConfig
	AIFeatureStatus AIFeatureStatus
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

	excludeEmployeeCoinAllocation := boolWithDefault("EXCLUDE_EMPLOYEE_COIN_ALLOCATION", true)
	enableQrValidations := boolWithDefault("ENABLE_QR_VALIDATIONS", true)

	sessionEndTimeOffsetMinutes := 15
	if v := os.Getenv("SESSION_END_TIME_OFFSET_MINUTES"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			sessionEndTimeOffsetMinutes = parsed
		}
	}

	sessionSlotMinutes := 5
	if v := os.Getenv("SESSION_SLOT_MINUTES"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			sessionSlotMinutes = parsed
		}
	}

	// Decoded best-effort here; Validate() is where a missing/malformed key
	// is actually rejected, matching this file's existing Load()-is-tolerant,
	// Validate()-is-strict split.
	piiEncryptionKey, piiKeyDecodeErr := base64.StdEncoding.DecodeString(os.Getenv("PII_ENCRYPTION_KEY"))

	venueTimezone := os.Getenv("VENUE_TIMEZONE")
	if venueTimezone == "" {
		venueTimezone = "UTC"
	}
	// Same tolerant-Load/strict-Validate split as the PII key: a bad zone name
	// is remembered here and reported by Validate() rather than panicking.
	venueLocation, venueTZLoadErr := time.LoadLocation(venueTimezone)

	aiRequestTimeoutSeconds := 120
	if v := os.Getenv("AI_REQUEST_TIMEOUT_SECONDS"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			aiRequestTimeoutSeconds = parsed
		}
	}

	return Config{
		DBHost:     os.Getenv("DB_HOST"),
		DBPort:     dbPort,
		DBUser:     os.Getenv("DB_USER"),
		DBPassword: os.Getenv("DB_PASSWORD"),
		DBName:     os.Getenv("DB_NAME"),
		DBSchema:   os.Getenv("DB_SCHEMA"),
		DBSSLMode:  dbSSLMode,
		Port:       port,
		LogLevel:   logLevel,
		AppEnv:     appEnv,

		JWKSEndpoint:          os.Getenv("JWKS_ENDPOINT"),
		Issuer:                os.Getenv("JWT_ISSUER"),
		Audience:              os.Getenv("JWT_AUDIENCE"),
		TokenValidatorEnabled: tokenValidatorEnabled,
		AdminRoles:            parseList(os.Getenv("RBAC_ADMIN_ROLES")),

		ExcludeEmployeeCoinAllocation: excludeEmployeeCoinAllocation,
		EnableQrValidations:           enableQrValidations,
		SessionEndTimeOffsetMinutes:   sessionEndTimeOffsetMinutes,
		SessionSlotMinutes:            sessionSlotMinutes,
		VenueTimezone:                 venueTimezone,
		VenueLocation:                 venueLocation,
		venueTZLoadErr:                venueTZLoadErr,
		PIIEncryptionKey:              piiEncryptionKey,
		piiKeyDecodeErr:               piiKeyDecodeErr,

		QRPortal: ExternalServiceConfig{
			Endpoint: os.Getenv("QR_PORTAL_ENDPOINT"),
			OAuth: OAuthClientConfig{
				TokenURL:     os.Getenv("QR_PORTAL_TOKEN_URL"),
				ClientID:     os.Getenv("QR_PORTAL_CLIENT_ID"),
				ClientSecret: os.Getenv("QR_PORTAL_CLIENT_SECRET"),
			},
		},
		Wallet: ExternalServiceConfig{
			Endpoint: os.Getenv("WALLET_ENDPOINT"),
			OAuth: OAuthClientConfig{
				TokenURL:     os.Getenv("WALLET_TOKEN_URL"),
				ClientID:     os.Getenv("WALLET_CLIENT_ID"),
				ClientSecret: os.Getenv("WALLET_CLIENT_SECRET"),
			},
		},
		Transaction: ExternalServiceConfig{
			Endpoint: os.Getenv("TRANSACTION_ENDPOINT"),
			OAuth: OAuthClientConfig{
				TokenURL:     os.Getenv("TRANSACTION_TOKEN_URL"),
				ClientID:     os.Getenv("TRANSACTION_CLIENT_ID"),
				ClientSecret: os.Getenv("TRANSACTION_CLIENT_SECRET"),
			},
		},

		AIAgent: AIAgentConfig{
			MatchmakingServiceURL:      os.Getenv("AI_MATCHMAKING_SERVICE_URL"),
			PersonalizeAgentServiceURL: os.Getenv("AI_PERSONALIZE_AGENT_SERVICE_URL"),
			PickedForYouServiceURL:     os.Getenv("AI_PICKED_FOR_YOU_SERVICE_URL"),
			ChatServiceURL:             os.Getenv("AI_CHAT_SERVICE_URL"),
			RequestTimeout:             time.Duration(aiRequestTimeoutSeconds) * time.Second,
		},
		AIFeatureStatus: AIFeatureStatus{
			EnabledChatAssistant:      boolWithDefault("AI_ENABLED_CHAT_ASSISTANT", false),
			EnabledPersonalizedAgenda: boolWithDefault("AI_ENABLED_PERSONALIZED_AGENDA", false),
			EnabledMatchMaker:         boolWithDefault("AI_ENABLED_MATCH_MAKER", false),
			EnabledO2Bar:              boolWithDefault("AI_ENABLED_O2_BAR", false),
		},
	}
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

// DSN assembles a libpq keyword=value connection string from individual vars.
// The keyword=value format avoids URL-encoding issues with special characters in passwords.
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
	if c.DBPassword == "" && c.AppEnv != "development" {
		return errors.New("DB_PASSWORD is required in non-development environments")
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
	if c.venueTZLoadErr != nil {
		return fmt.Errorf("VENUE_TIMEZONE %q is not a loadable IANA timezone: %w", c.VenueTimezone, c.venueTZLoadErr)
	}
	if c.TokenValidatorEnabled {
		if c.JWKSEndpoint == "" {
			return errors.New("JWKS_ENDPOINT is required when TOKEN_VALIDATOR_ENABLED=true")
		}
		if c.Issuer == "" {
			return errors.New("JWT_ISSUER is required when TOKEN_VALIDATOR_ENABLED=true")
		}
		if c.Audience == "" {
			return errors.New("JWT_AUDIENCE is required when TOKEN_VALIDATOR_ENABLED=true")
		}
	}
	return nil
}
