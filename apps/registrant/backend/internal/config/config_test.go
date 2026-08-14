// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package config

import "testing"

func validConfig() Config {
	return Config{
		DBHost:               "localhost",
		DBUser:               "root",
		DBName:               "conference",
		EmailServiceEndpoint: "https://email.example.com",
		EmailFrom:            "noreply@example.com",
		SheetsSpreadsheetID:  "sheet-id",
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
		{"missing email endpoint", func(c *Config) { c.EmailServiceEndpoint = "" }, "EMAIL_SERVICE_ENDPOINT is required"},
		{"missing email from", func(c *Config) { c.EmailFrom = "" }, "EMAIL_FROM is required"},
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

func TestValidate_OK(t *testing.T) {
	if err := validConfig().Validate(); err != nil {
		t.Fatalf("Validate() unexpected error: %v", err)
	}
}

func TestDSN(t *testing.T) {
	c := Config{DBUser: "root", DBPassword: "pw", DBHost: "localhost", DBPort: "3306", DBName: "conference"}
	want := "root:pw@tcp(localhost:3306)/conference?parseTime=true"
	if got := c.DSN(); got != want {
		t.Fatalf("DSN() = %q, want %q", got, want)
	}
}

func TestLoad_Defaults(t *testing.T) {
	t.Setenv("PORT", "")
	t.Setenv("DB_PORT", "")
	t.Setenv("LOG_LEVEL", "")
	t.Setenv("APP_ENV", "")

	c := Load()
	if c.Port != "8080" {
		t.Errorf("Port default = %q, want 8080", c.Port)
	}
	if c.DBPort != "3306" {
		t.Errorf("DBPort default = %q, want 3306", c.DBPort)
	}
	if c.LogLevel != "info" {
		t.Errorf("LogLevel default = %q, want info", c.LogLevel)
	}
	if c.AppEnv != "production" {
		t.Errorf("AppEnv default = %q, want production", c.AppEnv)
	}
}
