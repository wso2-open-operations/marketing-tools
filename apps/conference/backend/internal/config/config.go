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
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"wso2-coin-backend/internal/analytics"
)

// OAuthClientConfig holds OAuth2 client-credentials settings for an external service.
type OAuthClientConfig struct {
	TokenURL     string
	ClientID     string
	ClientSecret string
	// Scopes is optional and left empty by every integration except the
	// notification service, whose IdP client requires them explicitly.
	Scopes []string
}

// ExternalServiceConfig holds the base endpoint and OAuth2 credentials for an
// external service integration (QR portal, wallet, transaction/blockchain).
type ExternalServiceConfig struct {
	Endpoint string
	OAuth    OAuthClientConfig
}

// EmailServiceConfig holds configuration for the email service.
type EmailServiceConfig struct {
	Endpoint string
	OAuth    OAuthClientConfig
	From     string
}

// AIAgentConfig holds the base URL for the external AI agent service, the
// credentials used to reach it, and the request timeout applied to its calls.
// Matchmaking, personalize, picked-for-you and chat are one consolidated
// service that answers every one of those paths off a single root with no path
// prefix, so one URL configures all of them.
//
// Two credentials travel on every AI call and they answer different questions:
//
//   - x-jwt-assertion is the *caller's* own JWT, forwarded verbatim. It is how
//     the AI service knows which attendee is asking. It is not a credential the
//     AI service checks -- that service authenticates nobody.
//   - Authorization is *this* service's OAuth2 client-credentials token, and it
//     is for the Choreo gateway in front of the AI service, not for the service
//     itself. The AI service is published at Organization network visibility,
//     which restricts who can reach it but does not make it unauthenticated:
//     its gateway rejects a tokenless call with
//     401 {"code":"900901","error_message":"Invalid Credentials"}.
//
// This mirrors push-notification-gateway-api -> push-notification-service in
// digiops-superapp, a public-calls-organization pair reported to work in
// production; see CLAUDE.md, "Calling an Organization-visibility Choreo
// service", which records what that claim rests on.
//
// OAuth is optional, but only for a ServiceURL on this machine: leave
// OAuth.TokenURL empty and no token is fetched or sent, which is what a
// locally-run AI service with no gateway in front of it expects. Point
// ServiceURL anywhere else with the credentials blank and Validate() refuses to
// start -- see validateAIAgent.
//
// Every field is trimmed at load time (see Load), because these values are
// compared against "" in this package and parsed as URLs in the client, and
// those two disagree about "   ".
type AIAgentConfig struct {
	ServiceURL     string
	OAuth          OAuthClientConfig
	RequestTimeout time.Duration
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

// MoesifConfig configures the API-usage analytics sink in internal/analytics.
//
// Enabled defaults to false, so a deployment that says nothing about analytics
// gets none -- the same "everything off unless asked for" default the AI flags
// use. Unlike those, though, enabling it without an application id is a startup
// error rather than a silent no-op (see Validate): analytics that is switched on
// but throwing every event away looks exactly like a conference nobody attended,
// and that is the one wrong answer this feature must not produce.
type MoesifConfig struct {
	Enabled       bool
	ApplicationID string
	// APIEndpoint overrides Moesif's collector base URL. Empty means the global
	// collector; set it for Moesif EU or to point a test at a local stub.
	APIEndpoint string
	// ProjectName and AppName are stamped into every event's metadata.
	// ProjectName matches what the Ballerina conference service already writes
	// ("marketing-web") so the two services' events sit in one comparable
	// project; AppName differs from it deliberately, so they can still be told
	// apart.
	ProjectName string
	AppName     string
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

	StaleOrderCleanupIntervalSeconds int
	CoinStaleOrderTimeoutMinutes     int

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
	Email       EmailServiceConfig
	// Notification is the external WSO2 notification service that fans a
	// broadcast out to attendees' devices. This backend never talks to FCM
	// itself -- it hands the recipient list to that service and stops there.
	Notification ExternalServiceConfig

	// ShopMasterWalletAddress is the merchant wallet that shop payments must be
	// sent to (SHOP_MASTER_WALLET_ADDRESS). Checkout confirmation compares the
	// on-chain transfer's decoded recipient against it, which is what stops a
	// caller settling an order by pointing at an unrelated transfer.
	//
	// Left empty, POST /shops/checkout/confirm refuses every request rather than
	// skipping the recipient check -- a deployment that forgot to set this must
	// not hand out merchandise for free. Validate() does not require it, so a
	// deployment with no shop still starts.
	ShopMasterWalletAddress string

	// AI Features
	AIAgent         AIAgentConfig
	AIFeatureStatus AIFeatureStatus

	// Moesif is the API-usage analytics sink. Off unless MOESIF_ENABLED=true.
	Moesif MoesifConfig
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

	staleOrderCleanupIntervalSeconds := 300
	if v := os.Getenv("STALE_ORDER_CLEANUP_INTERVAL_SECONDS"); v != "" {
		if parsed, err := strconv.ParseFloat(v, 64); err == nil {
			staleOrderCleanupIntervalSeconds = int(parsed)
		}
	}

	coinStaleOrderTimeoutMinutes := 5
	if v := os.Getenv("COIN_STALE_ORDER_TIMEOUT_MINUTES"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			coinStaleOrderTimeoutMinutes = parsed
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
		// Only a positive value is accepted: http.Client reads Timeout <= 0 as
		// "no timeout at all", so AI_REQUEST_TIMEOUT_SECONDS=0 (or a negative)
		// parses fine and then removes the AI deadline entirely. The server's
		// write deadline still fires -- HTTPWriteTimeout floors at 130s -- so
		// gin truncates the response while the handler goes on waiting on an
		// upstream that may never answer. Anything non-positive falls back to
		// the default rather than being honoured.
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			aiRequestTimeoutSeconds = parsed
		}
	}

	moesifProjectName := os.Getenv("MOESIF_PROJECT_NAME")
	if moesifProjectName == "" {
		moesifProjectName = "marketing-web"
	}
	moesifAppName := os.Getenv("MOESIF_APP_NAME")
	if moesifAppName == "" {
		moesifAppName = "con-app-backend"
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

		ExcludeEmployeeCoinAllocation:    excludeEmployeeCoinAllocation,
		EnableQrValidations:              enableQrValidations,
		SessionEndTimeOffsetMinutes:      sessionEndTimeOffsetMinutes,
		SessionSlotMinutes:               sessionSlotMinutes,
		StaleOrderCleanupIntervalSeconds: staleOrderCleanupIntervalSeconds,
		CoinStaleOrderTimeoutMinutes:     coinStaleOrderTimeoutMinutes,
		VenueTimezone:                    venueTimezone,
		VenueLocation:                    venueLocation,
		venueTZLoadErr:                   venueTZLoadErr,
		PIIEncryptionKey:                 piiEncryptionKey,
		piiKeyDecodeErr:                  piiKeyDecodeErr,

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
		Email: EmailServiceConfig{
			Endpoint: os.Getenv("EMAIL_SERVICE_URL"),
			OAuth: OAuthClientConfig{
				TokenURL:     os.Getenv("EMAIL_OAUTH_TOKEN_URL"),
				ClientID:     os.Getenv("EMAIL_OAUTH_CLIENT_ID"),
				ClientSecret: os.Getenv("EMAIL_OAUTH_CLIENT_SECRET"),
			},
			From: os.Getenv("EMAIL_FROM"),
		},
		Notification: ExternalServiceConfig{
			Endpoint: os.Getenv("NOTIFICATION_ENDPOINT"),
			OAuth: OAuthClientConfig{
				TokenURL:     os.Getenv("NOTIFICATION_TOKEN_URL"),
				ClientID:     os.Getenv("NOTIFICATION_CLIENT_ID"),
				ClientSecret: os.Getenv("NOTIFICATION_CLIENT_SECRET"),
				Scopes:       parseList(os.Getenv("NOTIFICATION_SCOPES")),
			},
		},

		ShopMasterWalletAddress: strings.TrimSpace(os.Getenv("SHOP_MASTER_WALLET_ADDRESS")),

		AIAgent: AIAgentConfig{
			// Trimmed here, like SHOP_MASTER_WALLET_ADDRESS above, so the value
			// validateAIAgent inspects is the value the client actually sends.
			// Untrimmed, two config shapes that look fine at startup fail every
			// AI request:
			//
			//   - A secret pasted into a Choreo config field keeps its trailing
			//     newline. Validation compares with TrimSpace and passes, then
			//     http.NewRequest rejects the URL with "net/url: invalid control
			//     character in URL" -- a *url.Error, not an oauth2.RetrieveError,
			//     so the handlers classify it as an unreachable service and every
			//     AI route answers 503 "temporarily unavailable" forever, with
			//     nothing pointing at the credential. url.JoinPath on a padded
			//     AI_SERVICE_URL fails the same way ("first path segment in URL
			//     cannot contain colon").
			//   - Whitespace-only credentials count as unset in validateAIAgent
			//     (the local-dev, no-gateway shape it allows) but "   " != "" in
			//     the client, which then takes the OAuth branch with a blank
			//     token URL.
			ServiceURL: strings.TrimSpace(os.Getenv("AI_SERVICE_URL")),
			OAuth: OAuthClientConfig{
				TokenURL:     strings.TrimSpace(os.Getenv("AI_TOKEN_URL")),
				ClientID:     strings.TrimSpace(os.Getenv("AI_CLIENT_ID")),
				ClientSecret: strings.TrimSpace(os.Getenv("AI_CLIENT_SECRET")),
			},
			RequestTimeout: time.Duration(aiRequestTimeoutSeconds) * time.Second,
		},
		AIFeatureStatus: AIFeatureStatus{
			EnabledChatAssistant:      boolWithDefault("AI_ENABLED_CHAT_ASSISTANT", false),
			EnabledPersonalizedAgenda: boolWithDefault("AI_ENABLED_PERSONALIZED_AGENDA", false),
			EnabledMatchMaker:         boolWithDefault("AI_ENABLED_MATCH_MAKER", false),
			EnabledO2Bar:              boolWithDefault("AI_ENABLED_O2_BAR", false),
		},

		Moesif: MoesifConfig{
			Enabled:       boolWithDefault("MOESIF_ENABLED", false),
			ApplicationID: os.Getenv("MOESIF_APPLICATION_ID"),
			APIEndpoint:   os.Getenv("MOESIF_API_ENDPOINT"),
			ProjectName:   moesifProjectName,
			AppName:       moesifAppName,
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
	// When the token validator is on, JWKS/issuer/audience are all required --
	// signature verification and iss/aud checks cannot run without them. In
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
		if c.Audience == "" {
			return errors.New("JWT_AUDIENCE is required when TOKEN_VALIDATOR_ENABLED=true")
		}
	}
	// Deliberately strict rather than degrading to a no-op recorder: see
	// MoesifConfig. Analytics that is on and silently discarding is worse than
	// analytics that refuses to start.
	if c.Moesif.Enabled && c.Moesif.ApplicationID == "" {
		return errors.New("MOESIF_APPLICATION_ID is required when MOESIF_ENABLED=true")
	}
	// Every batch carries the application id as a header, so a plaintext
	// collector leaks a credential on the wire. Checked here as well as in
	// analytics.New so the deployer hears about a bad endpoint from the config
	// layer that owns the env var.
	if c.Moesif.Enabled {
		if err := analytics.CheckEndpoint(c.Moesif.APIEndpoint); err != nil {
			return err
		}
	}
	if err := c.validateAIAgent(); err != nil {
		return err
	}
	return nil
}

// validateAIAgent rejects the AI configurations that produce a service which
// boots happily and then fails every AI request.
//
// These checks exist because that exact deployment shipped: all four feature
// flags on, AI_SERVICE_URL pointing at a gateway, no credentials for it, and
// every AI route answering 500 with the real cause (a gateway 401) visible only
// in a log attribute. A flag that is on must mean the feature can actually
// work, so these fail at startup instead.
//
// "No credentials" cannot simply be banned, because it is also the correct
// local shape: an AI service run on the developer's own machine has no gateway
// in front of it and nothing to authenticate to. The address is what tells the
// two apart, so the credential requirement is keyed on it -- off-machine means
// a gateway is in the path.
func (c Config) validateAIAgent() error {
	anyAIEnabled := c.AIFeatureStatus.EnabledChatAssistant ||
		c.AIFeatureStatus.EnabledPersonalizedAgenda ||
		c.AIFeatureStatus.EnabledMatchMaker ||
		c.AIFeatureStatus.EnabledO2Bar
	if anyAIEnabled && c.AIAgent.ServiceURL == "" {
		return errors.New("AI_SERVICE_URL is required when any AI_ENABLED_* flag is true")
	}
	// Partial credentials are always a mistake: two thirds of a
	// client-credentials grant authenticates nothing, and the resulting 401
	// looks identical to sending no token at all.
	oauth := c.AIAgent.OAuth
	set := 0
	for _, v := range []string{oauth.TokenURL, oauth.ClientID, oauth.ClientSecret} {
		if v != "" {
			set++
		}
	}
	if set != 0 && set != 3 {
		return errors.New("AI_TOKEN_URL, AI_CLIENT_ID and AI_CLIENT_SECRET must be set together, or all left empty")
	}
	// Zero of three is a legal shape only for a local AI service. Anywhere else
	// it is the regression above verbatim, which the all-or-nothing rule alone
	// stays silent about.
	if anyAIEnabled && set == 0 && !isLocalServiceAddress(c.AIAgent.ServiceURL) {
		return errors.New("AI_TOKEN_URL, AI_CLIENT_ID and AI_CLIENT_SECRET are required when an AI_ENABLED_* flag is true and AI_SERVICE_URL is not a local address: the Choreo gateway in front of a remote AI service rejects a tokenless call with 401 900901, so every AI route would fail")
	}
	return nil
}

// isLocalServiceAddress reports whether rawURL names a service on this machine
// -- the one deployment shape that legitimately has no gateway, and so no
// credentials, in front of it.
//
// Matched on the parsed host rather than on substrings, so that
// "https://ai-localhost.example.com" is not mistaken for local. Anything that
// does not parse, or that carries no recognisable host, is reported as remote:
// the caller uses this to decide whether credentials may be omitted, and the
// safe answer when the address is unreadable is that they may not.
func isLocalServiceAddress(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	// Empty for a schemeless value like "localhost:8000", which url.Parse reads
	// as scheme "localhost" with opaque "8000" -- not an address this service
	// can call anyway.
	host := u.Hostname()
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	// Covers all of 127.0.0.0/8 and ::1; Hostname() has already stripped the
	// brackets from an "[::1]:8000" authority.
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

// httpWriteTimeoutFloor is the lower bound on the server's write deadline.
//
// One server-wide WriteTimeout has to serve both a 200ms /events read and a
// 120s AI chat turn, so it is set by the slowest route, not the typical one.
const httpWriteTimeoutFloor = 130 * time.Second

// HTTPWriteTimeout is the http.Server WriteTimeout, derived from the AI request
// budget rather than configured separately -- there is no new env var here.
//
// The deadline covers the whole response write, so it must outlive the longest
// upstream call the handler makes. It previously did not: a fixed 15s against
// AI_REQUEST_TIMEOUT_SECONDS=120 closed the connection mid-write on every AI
// response past 15s, and POST /users/profile (15-21s) failed client-side 100% of
// the time while the write it was reporting on had already landed.
//
// AIAgent.RequestTimeout + 10s leaves the AI client's own timeout as the thing
// that fires first, so a slow upstream still produces a real error response
// instead of a truncated connection.
func (c Config) HTTPWriteTimeout() time.Duration {
	if t := c.AIAgent.RequestTimeout + 10*time.Second; t > httpWriteTimeoutFloor {
		return t
	}
	return httpWriteTimeoutFloor
}

// InsecureAuthConfig reports a production deployment running with JWT signature
// validation switched off, which accepts forged alg=none and expired tokens.
//
// TOKEN_VALIDATOR_ENABLED still defaults to false on purpose: flipping the
// global default would break dev/test, which rely on it being off. Instead the
// AppEnv=="production" gate here is what enforces prod: main.go now FAILS CLOSED
// on this predicate, logging an error and exiting non-zero so a production
// container refuses to boot with signature validation off, rather than only
// warning and serving forged identities. It is deliberately not a Validate()
// failure -- Validate() has no view of "is this prod" beyond AppEnv, and keeping
// the refusal in main.go keeps the fail-closed decision in one place.
func (c Config) InsecureAuthConfig() bool {
	return c.AppEnv == "production" && !c.TokenValidatorEnabled
}

// ShopPaymentsConfigured reports whether a merchant wallet is set, i.e. whether
// POST /shops/checkout/confirm can verify anything at all.
//
// Not a Validate() requirement: a deployment with no shop must still start. It
// is warned at startup and answered per-request with a 503.
func (c Config) ShopPaymentsConfigured() bool {
	return c.ShopMasterWalletAddress != ""
}
