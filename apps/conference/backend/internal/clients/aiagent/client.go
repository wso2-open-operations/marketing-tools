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

// Package aiagent provides an HTTP client for the external AI agent
// services (matchmaking, personalize, picked-for-you, chat). Unlike
// qrportal/wallet/transaction, auth here is pure pass-through of the
// caller's own JWT via the x-jwt-assertion header -- no OAuth2 client
// credentials at all (see .claude/PLAN.md).
package aiagent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

// maxErrBodyBytes caps how much of an error response body we read into an
// error message, so a huge/unexpected body doesn't blow up logs.
const maxErrBodyBytes = 2048

// Client is an HTTP client for the external AI agent services.
type Client struct {
	matchmakingBaseURL      string
	personalizeAgentBaseURL string
	pickedForYouBaseURL     string
	chatBaseURL             string
	httpClient              *http.Client
}

// NewClient builds a production Client bounded by cfg.RequestTimeout.
func NewClient(cfg config.AIAgentConfig) *Client {
	return NewClientWithHTTPClient(cfg, &http.Client{Timeout: cfg.RequestTimeout})
}

// NewClientWithHTTPClient builds a Client using httpClient directly. This is
// intended for tests, where httpClient is typically an httptest.Server's
// client, but is also how NewClient assembles the production client.
func NewClientWithHTTPClient(cfg config.AIAgentConfig, httpClient *http.Client) *Client {
	return &Client{
		matchmakingBaseURL:      cfg.MatchmakingServiceURL,
		personalizeAgentBaseURL: cfg.PersonalizeAgentServiceURL,
		pickedForYouBaseURL:     cfg.PickedForYouServiceURL,
		chatBaseURL:             cfg.ChatServiceURL,
		httpClient:              httpClient,
	}
}

// RetrieveMatches fetches recommended matches for the caller via
// POST {matchmakingServiceURL}/networking/recommend, body {}.
func (c *Client) RetrieveMatches(ctx context.Context, jwtAssertion string) ([]models.RecommendedUser, error) {
	var out []models.RecommendedUser
	if err := c.postJSON(ctx, c.matchmakingBaseURL, "networking/recommend", jwtAssertion, struct{}{}, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving matches: %w", err)
	}
	return out, nil
}

// RetrieveO2BarRecommendations fetches O2Bar recommendations for the caller
// via POST {matchmakingServiceURL}/o2bar/recommend. When question is nil, no
// request body is sent at all -- not even "{}" -- matching the old
// `question is string ? {question} : ()` exactly.
func (c *Client) RetrieveO2BarRecommendations(ctx context.Context, jwtAssertion string, question *string) ([]models.O2BarRecommendationResponse, error) {
	var body any
	if question != nil {
		body = map[string]string{"question": *question}
	}

	var out []models.O2BarRecommendationResponse
	if err := c.postJSONOrNoBody(ctx, c.matchmakingBaseURL, "o2bar/recommend", jwtAssertion, body, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving O2Bar recommendations: %w", err)
	}
	return out, nil
}

// SendProfileInfo forwards profile to the external personalize agent
// service via POST {personalizeAgentServiceURL}/profile/create, body
// {"override": true, "user": profile}. It returns the raw *http.Response
// for the caller to copy through untouched (status, headers, body) --
// matching the old raw-passthrough behavior exactly. The caller must close
// the response body.
func (c *Client) SendProfileInfo(ctx context.Context, jwtAssertion string, profile models.PersonalizeAgentUserProfile) (*http.Response, error) {
	payload := map[string]any{"override": true, "user": profile}
	b, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("aiagent: encoding profile payload: %w", err)
	}

	req, err := c.newRequest(ctx, c.personalizeAgentBaseURL, "profile/create", jwtAssertion, bytes.NewReader(b))
	if err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("aiagent: sending profile info: %w", err)
	}
	return resp, nil
}

// RetrieveAgendaRecommendations fetches personalized "Picked for You" agenda
// recommendations via POST {pickedForYouServiceURL}/agenda/create, body {}.
// The external service returns fully-formed session objects itself -- no DB
// enrichment happens here.
func (c *Client) RetrieveAgendaRecommendations(ctx context.Context, jwtAssertion string) ([]models.PickedForYouSession, error) {
	var out []models.PickedForYouSession
	if err := c.postJSON(ctx, c.pickedForYouBaseURL, "agenda/create", jwtAssertion, struct{}{}, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving agenda recommendations: %w", err)
	}
	return out, nil
}

// RetrieveChatResponse forwards req to the external chat service via
// POST {chatServiceURL}/assistant/chat, body = the whole request.
func (c *Client) RetrieveChatResponse(ctx context.Context, jwtAssertion string, req models.ChatRequest) (*models.ChatResponse, error) {
	var out models.ChatResponse
	if err := c.postJSON(ctx, c.chatBaseURL, "assistant/chat", jwtAssertion, req, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving chat response: %w", err)
	}
	return &out, nil
}

// postJSON sends body (always JSON-encoded, even if empty) and decodes the
// response into out.
func (c *Client) postJSON(ctx context.Context, baseURL, path, jwtAssertion string, body, out any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("encoding request body: %w", err)
	}
	return c.doJSON(ctx, baseURL, path, jwtAssertion, bytes.NewReader(b), out)
}

// postJSONOrNoBody sends body JSON-encoded, or no request body at all when
// body is nil, and decodes the response into out.
func (c *Client) postJSONOrNoBody(ctx context.Context, baseURL, path, jwtAssertion string, body, out any) error {
	if body == nil {
		return c.doJSON(ctx, baseURL, path, jwtAssertion, nil, out)
	}
	return c.postJSON(ctx, baseURL, path, jwtAssertion, body, out)
}

func (c *Client) doJSON(ctx context.Context, baseURL, path, jwtAssertion string, bodyReader io.Reader, out any) error {
	req, err := c.newRequest(ctx, baseURL, path, jwtAssertion, bodyReader)
	if err != nil {
		return err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("request to %s failed: %w", req.URL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrBodyBytes))
		return fmt.Errorf("POST %s returned status %d: %s", req.URL, resp.StatusCode, errBody)
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decoding response body: %w", err)
	}
	return nil
}

func (c *Client) newRequest(ctx context.Context, baseURL, path, jwtAssertion string, bodyReader io.Reader) (*http.Request, error) {
	reqURL, err := url.JoinPath(baseURL, path)
	if err != nil {
		return nil, fmt.Errorf("building URL: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, reqURL, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("building request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-jwt-assertion", jwtAssertion)
	return req, nil
}
