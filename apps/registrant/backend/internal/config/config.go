// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package config

import (
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

	// Database (MySQL)
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string

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
		dbPort = "3306"
	}
	logLevel := os.Getenv("LOG_LEVEL")
	if logLevel == "" {
		logLevel = "info"
	}
	appEnv := os.Getenv("APP_ENV")
	if appEnv == "" {
		appEnv = "production"
	}

	return Config{
		Port:     port,
		LogLevel: logLevel,
		AppEnv:   appEnv,

		DBHost:     os.Getenv("DB_HOST"),
		DBPort:     dbPort,
		DBUser:     os.Getenv("DB_USER"),
		DBPassword: os.Getenv("DB_PASSWORD"),
		DBName:     os.Getenv("DB_NAME"),

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

// DSN assembles a go-sql-driver/mysql data source name from individual vars.
func (c Config) DSN() string {
	return fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?parseTime=true",
		c.DBUser, c.DBPassword, c.DBHost, c.DBPort, c.DBName,
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
