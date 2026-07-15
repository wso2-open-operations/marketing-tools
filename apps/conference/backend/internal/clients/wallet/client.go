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

// Package wallet provides an HTTP client for the external Wallet service,
// used to look up a user's primary blockchain wallet during the WSO2 Coin /
// O2C flow.
package wallet

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"

	"golang.org/x/oauth2/clientcredentials"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

// maxErrBodyBytes caps how much of an error response body we read into an
// error message, so a huge/unexpected body doesn't blow up logs.
const maxErrBodyBytes = 2048

// Client is an HTTP client for the external Wallet service.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient builds a production Client that authenticates to the Wallet
// service using OAuth2 client-credentials, per cfg. The returned client is
// lazy: it does not contact the token endpoint until the first real HTTP
// request is made.
func NewClient(cfg config.ExternalServiceConfig) *Client {
	oauthCfg := clientcredentials.Config{
		ClientID:     cfg.OAuth.ClientID,
		ClientSecret: cfg.OAuth.ClientSecret,
		TokenURL:     cfg.OAuth.TokenURL,
	}
	return &Client{
		baseURL:    cfg.Endpoint,
		httpClient: oauthCfg.Client(context.Background()),
	}
}

// NewClientWithHTTPClient builds a Client pointed at baseURL using httpClient
// directly, bypassing OAuth2 entirely. This is intended for tests, where
// httpClient is typically an httptest.Server's client.
func NewClientWithHTTPClient(baseURL string, httpClient *http.Client) *Client {
	return &Client{
		baseURL:    baseURL,
		httpClient: httpClient,
	}
}

// GetPrimaryWallet fetches a user's primary wallet via
// GET {baseURL}/wallets/primary?email={email}.
//
// A 404 response means "no wallet exists for this user" and is NOT treated as
// an error: it returns (nil, nil) so callers can distinguish "no wallet" from
// "lookup failed". Any other non-2xx status is returned as an error.
func (c *Client) GetPrimaryWallet(ctx context.Context, email string) (*models.Wallet, error) {
	query := url.Values{}
	query.Set("email", email)
	reqURL := c.baseURL + "/wallets/primary?" + query.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("wallet: building request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("wallet: request to %s failed: %w", reqURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrBodyBytes))
		return nil, fmt.Errorf("wallet: GET %s returned status %d: %s", reqURL, resp.StatusCode, body)
	}

	var w models.Wallet
	if err := json.NewDecoder(resp.Body).Decode(&w); err != nil {
		return nil, fmt.Errorf("wallet: decoding response body: %w", err)
	}

	return &w, nil
}
