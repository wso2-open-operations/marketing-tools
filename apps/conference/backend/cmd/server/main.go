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

package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"wso2-coin-backend/internal/clients/aiagent"
	"wso2-coin-backend/internal/clients/email"
	"wso2-coin-backend/internal/clients/notification"
	"wso2-coin-backend/internal/clients/qrportal"
	"wso2-coin-backend/internal/clients/transaction"
	"wso2-coin-backend/internal/clients/wallet"
	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/db"
	"wso2-coin-backend/internal/features"
	"wso2-coin-backend/internal/handlers"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/repository"
	"wso2-coin-backend/internal/service"

	"github.com/joho/godotenv"

	"github.com/gin-gonic/gin"
)

// dbWarmupTimeout bounds the startup ping that opens the pool's first
// connection. Generous on purpose: it delays the listener rather than a request,
// and the whole point is to absorb a slow cross-region dial here instead of
// inside a schema capability probe. On expiry the server comes up anyway.
const dbWarmupTimeout = 15 * time.Second

func main() {
	_ = godotenv.Load(".env")
	_ = godotenv.Overload(".env.local") // local overrides; ignored if absent

	cfg := config.Load()

	if err := cfg.Validate(); err != nil {
		slog.Error("invalid config", "error", err)
		os.Exit(1)
	}

	var level slog.Level
	switch strings.ToLower(cfg.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	opts := &slog.HandlerOptions{Level: level}
	var handler slog.Handler
	if cfg.AppEnv == "development" {
		handler = slog.NewTextHandler(os.Stdout, opts)
	} else {
		handler = slog.NewJSONHandler(os.Stdout, opts)
	}
	logger := slog.New(handler)
	slog.SetDefault(logger)

	slog.Info("logger initialised", "level", cfg.LogLevel, "env", cfg.AppEnv)

	// Fail closed: a production deployment with JWT signature validation off
	// accepts forged and expired tokens (ParseUnverified decodes claims without
	// verifying signature or expiry), letting any gateway-accepted Bearer forge
	// the x-jwt-assertion header to impersonate any user or add admin groups. A
	// crash-loop is strictly better than silently authenticating forged
	// identities, so this is now a hard startup failure, not a warning. Prod MUST
	// set TOKEN_VALIDATOR_ENABLED=true (plus JWKS/issuer/audience, which
	// cfg.Validate then requires). See config.InsecureAuthConfig.
	if cfg.InsecureAuthConfig() {
		slog.Error("SECURITY: refusing to boot -- TOKEN_VALIDATOR_ENABLED is false in a production "+
			"environment; JWT signatures would NOT be verified and forged or expired tokens would be "+
			"accepted. Set TOKEN_VALIDATOR_ENABLED=true and JWKS_ENDPOINT/JWT_ISSUER/JWT_AUDIENCE.",
			"appEnv", cfg.AppEnv)
		os.Exit(1)
	}
	// A warning, not a startup failure: a deployment with no shop is misconfigured
	// for checkout but must still boot and serve every other route, answering
	// /shops/checkout/confirm per-request with a 503. See config.ShopPaymentsConfigured.
	if !cfg.ShopPaymentsConfigured() {
		slog.Warn("SHOP_MASTER_WALLET_ADDRESS is not set; POST /shops/checkout/confirm will refuse every request with 503")
	}

	pool, err := db.Connect(context.Background(), cfg.DSN())
	if err != nil {
		slog.Error("db connect", "error", err)
		os.Exit(1)
	}

	// db.Connect only parses the DSN -- pgxpool dials lazily, so without this
	// the first request to arrive pays the connect, and against the staging
	// Azure instance that is ~2.6s of TLS and auth. That cost landing inside a
	// request is not merely slow: it lands inside whichever schema capability
	// probe runs first (see repository.probeContext), and a probe that runs out
	// of time degrades. For GET /activities it degrades to an empty array,
	// which the ETag middleware then stamps cacheable for a minute. Paying the
	// dial here, before the listener is up, is what keeps the first request
	// after a restart as truthful as the second.
	//
	// A failure is warned and not fatal, deliberately. Startup gating on the
	// database is a different decision than warming the pool, and this is only
	// the second one: an unreachable database at boot leaves the server up and
	// every request erroring, exactly as it did before this call existed,
	// rather than crash-looping the container. The pool re-dials per request,
	// so a database that comes back needs no restart.
	warmCtx, cancelWarm := context.WithTimeout(context.Background(), dbWarmupTimeout)
	if err := pool.Ping(warmCtx); err != nil {
		slog.Warn("db warm-up ping failed; first request will pay the connect", "error", err)
	} else {
		slog.Info("db connected")
	}
	cancelWarm()

	attendeeRepo := repository.NewAttendeeRepo(pool, cfg.PIIEncryptionKey)
	coinAllocationRepo := repository.NewCoinAllocationRepo(pool)
	sessionRepo := repository.NewSessionRepo(pool, cfg.SessionSlotMinutes, cfg.PIIEncryptionKey, cfg.VenueLocation)
	speakerRepo := repository.NewSpeakerRepo(pool, cfg.PIIEncryptionKey, cfg.SessionSlotMinutes, cfg.VenueLocation)
	eventRepo := repository.NewEventRepo(pool, cfg.SessionSlotMinutes, cfg.PIIEncryptionKey, cfg.VenueLocation, cfg.VenueTimezone)
	attendeeProfileRepo := repository.NewAttendeeProfileRepo(pool, cfg.PIIEncryptionKey)
	connectionRepo := repository.NewConnectionRepo(pool, attendeeProfileRepo)
	feedbackRepo := repository.NewFeedbackRepo(pool)
	appConfigRepo := repository.NewAppConfigRepo(pool)
	favoritesRepo := repository.NewFavoritesRepo(pool)
	activityRepo := repository.NewActivityRepo(pool, cfg.VenueLocation)
	shopRepo := repository.NewShopRepo(pool)
	leaderboardRepo := repository.NewLeaderboardRepo(pool, cfg.PIIEncryptionKey)

	// Feature flags live in app_config, so the resolver reads through the same
	// repo the /app-configs route serves from -- no second query, no second
	// source of truth. It caches for features.DefaultTTL, which is the lag
	// between flipping a row and the API acting on it.
	featureResolver := features.NewResolver(appConfigRepo)

	qrPortalClient := qrportal.NewClient(cfg.QRPortal)
	walletClient := wallet.NewClient(cfg.Wallet)
	transactionClient := transaction.NewClient(cfg.Transaction)
	aiAgentClient := aiagent.NewClient(cfg.AIAgent)
	emailClient := email.NewClient(cfg.Email)
	notificationClient := notification.NewClient(cfg.Notification)

	coinService := service.NewCoinService(
		attendeeRepo,
		coinAllocationRepo,
		sessionRepo,
		eventRepo,
		qrPortalClient,
		walletClient,
		service.ScanConfig{
			ExcludeEmployeeCoinAllocation: cfg.ExcludeEmployeeCoinAllocation,
			EnableQrValidations:           cfg.EnableQrValidations,
			SessionEndTimeOffsetMinutes:   cfg.SessionEndTimeOffsetMinutes,
		},
	)

	shopService := service.NewShopService(shopRepo, transactionClient, emailClient, service.ShopConfig{
		MasterWalletAddress: cfg.ShopMasterWalletAddress,
		StaleOrderCleanupIntervalSeconds: cfg.StaleOrderCleanupIntervalSeconds,
		CoinStaleOrderTimeoutMinutes: cfg.CoinStaleOrderTimeoutMinutes,
	})
	
	// Start the cron job for cancelling stale shop orders
	go shopService.Start(context.Background())
	coinHandler := handlers.NewCoinHandler(coinService, coinAllocationRepo, qrPortalClient, eventRepo, cfg.AdminRoles)
	speakerHandler := handlers.NewSpeakerHandler(speakerRepo)
	sessionHandler := handlers.NewSessionHandler(sessionRepo)
	eventHandler := handlers.NewEventHandler(eventRepo)
	attendeeHandler := handlers.NewAttendeeHandler(attendeeProfileRepo)
	connectionHandler := handlers.NewConnectionHandler(connectionRepo, attendeeProfileRepo)
	favoritesHandler := handlers.NewFavoritesHandler(favoritesRepo)
	feedbackHandler := handlers.NewFeedbackHandler(feedbackRepo, eventRepo)
	appConfigHandler := handlers.NewAppConfigHandler(appConfigRepo, featureResolver, cfg.ShopMasterWalletAddress)
	notificationHandler := handlers.NewNotificationHandler(attendeeProfileRepo, notificationClient, cfg.AdminRoles)
	activityHandler := handlers.NewActivityHandler(activityRepo)
	shopHandler := handlers.NewShopHandler(shopService)
	walletHandler := handlers.NewWalletHandler(walletClient, transactionClient)
	aiAgentHandler := handlers.NewAIAgentHandler(aiAgentClient, attendeeProfileRepo, cfg.AIFeatureStatus, sessionRepo)
	leaderboardHandler := handlers.NewLeaderboardHandler(leaderboardRepo, eventRepo)

	r := gin.New()

	if cfg.AppEnv == "development" {
		r.Use(func(c *gin.Context) {
			c.Header("Access-Control-Allow-Origin", "*")
			// PUT/DELETE back favorites; PATCH backs the attendee update.
			c.Header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
			c.Header("Access-Control-Allow-Headers", "Content-Type,x-jwt-assertion")
			if c.Request.Method == http.MethodOptions {
				c.AbortWithStatus(http.StatusNoContent)
				return
			}
			c.Next()
		})
	}

	r.Use(middleware.Logger(logger))
	r.Use(gin.Recovery())

	// /health stays outside the JWT-gated group: load balancer/k8s liveness
	// and readiness probes hit this without a JWT, so gating it would break
	// infra health checks rather than just API access.
	r.GET("/health", func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	api := r.Group("/")
	api.Use(middleware.Auth(middleware.AuthConfig{
		JWKSEndpoint:          cfg.JWKSEndpoint,
		Issuer:                cfg.Issuer,
		Audience:              cfg.Audience,
		ClockSkew:             5 * time.Minute,
		TokenValidatorEnabled: cfg.TokenValidatorEnabled,
	}))
	// Applied to the whole group rather than per route: which routes belong to
	// which feature is a row in app_config (features.GateMapKey), so gating a
	// new route is an UPDATE, not a release. A route absent from that mapping
	// passes straight through. Ordered after Auth so an unauthenticated caller
	// cannot probe which features exist.
	api.Use(middleware.FeatureGate(featureResolver))
	{
		// Conference data is read-only and changes rarely, so these GETs carry
		// ETag + Cache-Control validators.
		cacheable := middleware.ETag("private, max-age=60, must-revalidate")
		api.GET("/speakers", cacheable, speakerHandler.List)
		api.GET("/speakers/:id", cacheable, speakerHandler.Get)
		api.GET("/sessions/current", cacheable, sessionHandler.Current)
		api.GET("/sessions/:id", cacheable, sessionHandler.Get)
		api.GET("/events", cacheable, eventHandler.List)
		// Registered ahead of the :eventId wildcard below. gin resolves a static
		// segment before a param at the same depth, the same way
		// /sessions/current and /sessions/:id already coexist here.
		api.GET("/events/current", cacheable, eventHandler.Current)
		api.GET("/events/:eventId/agendas", cacheable, eventHandler.Agendas)
		api.GET("/event-agendas", cacheable, eventHandler.LegacyAgendas)
		api.GET("/activities", cacheable, activityHandler.List)

		api.POST("/qr/scan", coinHandler.Scan)
		api.GET("/qr/history", coinHandler.History)
		api.GET("/qr/summary", coinHandler.Summary)
		api.GET("/qr-codes", coinHandler.GetGeneratedQRs)

		api.POST("/attendees", attendeeHandler.Create)
		api.PATCH("/attendees", attendeeHandler.Patch)
		api.GET("/attendees/me", attendeeHandler.Me)
		api.GET("/user-profile", attendeeHandler.Profile)
		api.POST("/attendees/search", attendeeHandler.Search)

		api.GET("/users/me/connections", connectionHandler.Get)
		api.POST("/users/me/connections", connectionHandler.Create)
		api.POST("/users/me/connections/:id/accept", connectionHandler.Accept)
		api.DELETE("/users/me/connections/:id", connectionHandler.Delete)

		api.GET("/users/me/favorites", favoritesHandler.List)
		api.PUT("/users/me/favorites/:sessionId", favoritesHandler.Add)
		api.DELETE("/users/me/favorites/:sessionId", favoritesHandler.Remove)

		api.POST("/feedback", feedbackHandler.Create)

		// Admin-gated broadcast: restricted to RBAC_ADMIN_ROLES groups.
		api.POST("/users/notifications", notificationHandler.Create)

		api.GET("/app-configs", appConfigHandler.List)

		// Shop. The catalog is the only cacheable one: stock moves, but a 60s
		// validator is what the client already polls at, and order history and
		// both checkout steps must never be served from a validator.
		api.GET("/shops/items", cacheable, shopHandler.Items)
		api.GET("/shops/orders/me", shopHandler.Orders)
		api.POST("/shops/checkout", shopHandler.Checkout)
		api.POST("/shops/checkout/confirm", shopHandler.ConfirmCheckout)

		api.GET("/wallets/balances/me", walletHandler.Balance)
		api.GET("/ai-maintenance-status", aiAgentHandler.MaintenanceStatus)
		api.GET("/users/me/matches", aiAgentHandler.Matches)
		api.GET("/o2bar/recommendations", aiAgentHandler.O2BarRecommendationsGet)
		api.POST("/o2bar/recommendations", aiAgentHandler.O2BarRecommendationsPost)
		api.POST("/users/profile", aiAgentHandler.PersonalizedProfile)
		api.GET("/agenda/recommendations", aiAgentHandler.AgendaRecommendations)
		api.POST("/assistant/chat", aiAgentHandler.Chat)
		// Leaderboard route
		api.GET("/leaderboard", leaderboardHandler.GetLeaderboard)
		api.GET("/leaderboard/preferences", leaderboardHandler.GetPreferences)
		api.PUT("/leaderboard/preferences", leaderboardHandler.UpdatePreferences)
	}

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		// Derived from the AI request budget, not fixed: a server-wide 15s
		// deadline cut every AI response off mid-write. See
		// config.HTTPWriteTimeout.
		WriteTimeout: cfg.HTTPWriteTimeout(),
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		slog.Info("server listening", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()

	slog.Info("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "error", err)
	}
	pool.Close()
	slog.Info("shutdown complete")
}
