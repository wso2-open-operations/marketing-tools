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

// Package qrportal provides an HTTP client for the external QR Portal service,
// which stores QR code metadata (event type, session, coin value, etc.) scanned
// during the WSO2 Coin / O2C flow.
package qrportal

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

const (
	// maxErrBodyBytes caps how much of an error response body we read into an
	// error message, so a huge/unexpected body doesn't blow up logs.
	maxErrBodyBytes = 2048
	// oauthHTTPTimeout bounds both the OAuth2 token fetch and the actual API
	// request, so an unreachable IdP or upstream service can't hang the scan
	// flow indefinitely.
	oauthHTTPTimeout = 15 * time.Second
)

// Client is an HTTP client for the external QR Portal service.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient builds a production Client that authenticates to the QR Portal
// using OAuth2 client-credentials, per cfg. The returned client is lazy: it
// does not contact the token endpoint until the first real HTTP request is made.
func NewClient(cfg config.ExternalServiceConfig) *Client {
	oauthCfg := clientcredentials.Config{
		ClientID:     cfg.OAuth.ClientID,
		ClientSecret: cfg.OAuth.ClientSecret,
		TokenURL:     cfg.OAuth.TokenURL,
	}
	// oauth2.HTTPClient bounds the token-fetch request; the same timeout is
	// applied to the returned client below to also bound the actual API call.
	tokenFetchCtx := context.WithValue(context.Background(), oauth2.HTTPClient, &http.Client{Timeout: oauthHTTPTimeout})
	httpClient := oauthCfg.Client(tokenFetchCtx)
	httpClient.Timeout = oauthHTTPTimeout
	return &Client{
		baseURL:    cfg.Endpoint,
		httpClient: httpClient,
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

// GetQRCode fetches a QR code's metadata from the external QR Portal service
// via GET {baseURL}/qr-codes/{qrID}. Any non-2xx response is treated as an
// error; there is no special handling for a 404 here (unlike the wallet client).
func (c *Client) GetQRCode(ctx context.Context, qrID string) (*models.ConferenceQrCode, error) {
	reqURL, err := url.JoinPath(c.baseURL, "qr-codes", qrID)
	if err != nil {
		return nil, fmt.Errorf("qrportal: building URL: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("qrportal: building request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("qrportal: request to %s failed: %w", reqURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrBodyBytes))
		return nil, fmt.Errorf("qrportal: GET %s returned status %d: %s", reqURL, resp.StatusCode, body)
	}

	var qrCode models.ConferenceQrCode
	if err := json.NewDecoder(resp.Body).Decode(&qrCode); err != nil {
		return nil, fmt.Errorf("qrportal: decoding response body: %w", err)
	}

	return &qrCode, nil
}
