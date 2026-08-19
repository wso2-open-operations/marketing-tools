// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

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

	"attendee-registration/internal/config"
	"attendee-registration/internal/crypto"
	"attendee-registration/internal/handlers"
	"attendee-registration/internal/middleware"
	"attendee-registration/internal/repository"
	"attendee-registration/internal/sheets"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
)

func main() {
	_ = godotenv.Load(".env")
	_ = godotenv.Overload(".env.local") // local overrides; ignored if absent

	cfg := config.Load()

	if err := cfg.Validate(); err != nil {
		slog.Error("invalid config", "error", err)
		os.Exit(1)
	}

	if err := crypto.Init(cfg.PIIEncryptionKey); err != nil {
		slog.Error("crypto init", "error", err)
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

	db, err := repository.Connect(context.Background(), cfg.DSN(), repository.PoolConfig{
		MaxOpenConns:    cfg.DBMaxOpenConns,
		ConnMaxLifetime: cfg.ConnMaxLifetime(),
		MaxIdleConns:    cfg.DBMaxIdleConns,
	})
	if err != nil {
		slog.Error("db connect", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	slog.Info("db connected")

	repo := repository.New(db)
	agendaH := handlers.NewAgendaHandler(repo)

	sheetsClient, err := sheets.NewClient(context.Background(), sheets.Config{
		ClientID:      cfg.SheetsClientID,
		ClientSecret:  cfg.SheetsClientSecret,
		RefreshToken:  cfg.SheetsRefreshToken,
		TokenURL:      cfg.SheetsTokenURL,
		SpreadsheetID: cfg.SheetsSpreadsheetID,
		SheetID:       int64(cfg.SheetsSheetID),
		SheetName:     cfg.SheetsSheetName,
		SheetURL:      cfg.SheetsURL,
	})
	if err != nil {
		slog.Error("sheets client init", "error", err)
		os.Exit(1)
	}

	syncH := handlers.NewSyncHandler(repo, sheetsClient)

	r := gin.New()
	r.Use(gin.Recovery())

	api := r.Group("")
	api.Use(middleware.JwtInterceptor())
	{
		api.GET("/events/current/agendas", agendaH.ListCurrentAgendas)
		api.POST("/agendas/:agendaId/attendees", agendaH.RegisterAttendee)
		api.GET("/agendas/:agendaId/attendees/count", agendaH.AttendeeCount)
		api.POST("/attendees/sync", syncH.SyncAttendees)
	}

	srv := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: r,
		// Bounded so a slow/hostile client can't hold a connection open
		// indefinitely — app-layer defense in depth alongside the Choreo
		// gateway's own limits.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
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
	slog.Info("shutdown complete")
}
