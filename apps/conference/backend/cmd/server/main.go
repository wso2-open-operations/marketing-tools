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

	"wso2-coin-backend/internal/clients/qrportal"
	"wso2-coin-backend/internal/clients/wallet"
	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/db"
	"wso2-coin-backend/internal/handlers"
	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/repository"
	"wso2-coin-backend/internal/service"

	"github.com/joho/godotenv"

	"github.com/gin-gonic/gin"
)

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

	pool, err := db.Connect(context.Background(), cfg.DSN())
	if err != nil {
		slog.Error("db connect", "error", err)
		os.Exit(1)
	}

	slog.Info("db connected")

	attendeeRepo := repository.NewAttendeeRepo(pool)
	coinAllocationRepo := repository.NewCoinAllocationRepo(pool)
	sessionRepo := repository.NewSessionRepo(pool, cfg.SessionSlotMinutes, cfg.PIIEncryptionKey)
	speakerRepo := repository.NewSpeakerRepo(pool, cfg.PIIEncryptionKey)

	qrPortalClient := qrportal.NewClient(cfg.QRPortal)
	walletClient := wallet.NewClient(cfg.Wallet)

	coinService := service.NewCoinService(
		attendeeRepo,
		coinAllocationRepo,
		sessionRepo,
		qrPortalClient,
		walletClient,
		service.ScanConfig{
			ExcludeEmployeeCoinAllocation: cfg.ExcludeEmployeeCoinAllocation,
			EnableQrValidations:           cfg.EnableQrValidations,
			SessionEndTimeOffsetMinutes:   cfg.SessionEndTimeOffsetMinutes,
		},
	)

	coinHandler := handlers.NewCoinHandler(coinService, coinAllocationRepo)
	speakerHandler := handlers.NewSpeakerHandler(speakerRepo)
	sessionHandler := handlers.NewSessionHandler(sessionRepo)

	r := gin.New()

	if cfg.AppEnv == "development" {
		r.Use(func(c *gin.Context) {
			c.Header("Access-Control-Allow-Origin", "*")
			c.Header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
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

	r.GET("/health", func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	// Public conference data, unauthenticated: the old Ballerina service's
	// request interceptor never rejected requests missing x-jwt-assertion for
	// these resources, so they stay outside the JWT-gated api group below to
	// match that contract.
	r.GET("/speakers", speakerHandler.List)
	r.GET("/speakers/:id", speakerHandler.Get)
	r.GET("/sessions/current", sessionHandler.Current)
	r.GET("/sessions/:id", sessionHandler.Get)

	api := r.Group("/")
	api.Use(middleware.Auth(middleware.AuthConfig{
		JWKSEndpoint:          cfg.JWKSEndpoint,
		Issuer:                cfg.Issuer,
		Audience:              cfg.Audience,
		ClockSkew:             5 * time.Minute,
		TokenValidatorEnabled: cfg.TokenValidatorEnabled,
	}))
	{
		api.POST("/qr/scan", coinHandler.Scan)
		api.GET("/qr/history", coinHandler.History)
		api.GET("/qr/summary", coinHandler.Summary)
	}

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
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
