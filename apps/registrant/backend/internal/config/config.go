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
	return nil
}
