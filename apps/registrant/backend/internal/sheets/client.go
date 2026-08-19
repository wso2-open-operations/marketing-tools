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

package sheets

import (
	"context"

	"golang.org/x/oauth2"
	"google.golang.org/api/option"
	sheetsapi "google.golang.org/api/sheets/v4"
)

// Client wraps the Google Sheets API, authenticating with a long-lived
// OAuth2 refresh token (access tokens are fetched/refreshed lazily and
// cached by the underlying oauth2 transport).
type Client struct {
	svc    *sheetsapi.Service
	config Config
}

func NewClient(ctx context.Context, cfg Config) (*Client, error) {
	oauthCfg := &oauth2.Config{
		ClientID:     cfg.ClientID,
		ClientSecret: cfg.ClientSecret,
		Endpoint:     oauth2.Endpoint{TokenURL: cfg.TokenURL},
	}
	tokenSource := oauthCfg.TokenSource(ctx, &oauth2.Token{RefreshToken: cfg.RefreshToken})

	svc, err := sheetsapi.NewService(ctx, option.WithTokenSource(tokenSource))
	if err != nil {
		return nil, err
	}
	return &Client{svc: svc, config: cfg}, nil
}

// newClient builds a Client around an already-constructed Sheets service,
// letting tests point it at a fake HTTP server instead of the real API.
func newClient(svc *sheetsapi.Service, cfg Config) *Client {
	return &Client{svc: svc, config: cfg}
}
