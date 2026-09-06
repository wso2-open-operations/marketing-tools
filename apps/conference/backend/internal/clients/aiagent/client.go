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

// Package aiagent provides an HTTP client for the external AI agent service.
// Matchmaking, personalize, picked-for-you and chat are one consolidated
// service serving all of those paths off a single root with no path prefix,
// so every call in this package shares one base URL.
//
// Every request carries two credentials, answering two different questions:
// x-jwt-assertion is the caller's own JWT forwarded verbatim, which is how the
// AI service knows which attendee is asking; Authorization is this service's
// own OAuth2 client-credentials token, which is for the Choreo gateway in front
// of the AI service. The AI service authenticates nobody -- the token never
// reaches it -- but its gateway rejects a tokenless call outright. See
// config.AIAgentConfig and CLAUDE.md.
package aiagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"

	"wso2-coin-backend/internal/config"
	"wso2-coin-backend/internal/models"
)

// maxErrBodyBytes caps how much of an error response body we read into an
// error message, so a huge/unexpected body doesn't blow up logs.
const maxErrBodyBytes = 2048

// StatusError is returned when the AI service, or a gateway in front of it,
// answers with a non-2xx status. It carries the status out of this package so
// handlers can log it in the message itself rather than burying it in an
// attribute -- the deployed log viewer renders only the message, which is how a
// gateway 401 spent a day looking like an unexplained 500.
type StatusError struct {
	StatusCode int
	URL        string
	Body       string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("POST %s returned status %d: %s", e.URL, e.StatusCode, e.Body)
}

// StatusCodeFrom reports the upstream HTTP status carried by err, and whether
// err was an upstream status failure at all.
func StatusCodeFrom(err error) (int, bool) {
	var statusErr *StatusError
	if errors.As(err, &statusErr) {
		return statusErr.StatusCode, true
	}
	return 0, false
}

// TokenFetchStatusFrom reports the status the OAuth2 token endpoint answered
// with, and whether err was a token-fetch failure at all.
//
// This failure never reaches the AI service: the oauth2 transport gives up
// before sending the request, so it presents as a transport error even though
// nothing about the AI service is wrong. Telling the two apart is what stops a
// rejected client secret from being reported as "AI service unavailable".
func TokenFetchStatusFrom(err error) (int, bool) {
	var retrieveErr *oauth2.RetrieveError
	if errors.As(err, &retrieveErr) {
		if retrieveErr.Response != nil {
			return retrieveErr.Response.StatusCode, true
		}
		return 0, true
	}
	return 0, false
}

// Client is an HTTP client for the external AI agent service.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient builds a production Client bounded by cfg.RequestTimeout.
//
// With cfg.OAuth.TokenURL set, every request carries an OAuth2
// client-credentials token for the Choreo gateway fronting the AI service. The
// token is fetched lazily on the first call, then cached and refreshed by the
// oauth2 transport. AuthStyleInHeader presents the client id and secret as HTTP
// Basic at the token endpoint, which is what Asgardeo expects and what the
// push-notification gateway does by hand; without it the oauth2 package spends
// a probe request per process discovering the same thing.
//
// An empty TokenURL means no gateway -- the AI service addressed directly, as
// when it runs on localhost -- and no Authorization header is sent. Either way
// x-jwt-assertion still travels on every request: the gateway token identifies
// this service, never the attendee.
func NewClient(cfg config.AIAgentConfig) *Client {
	if cfg.OAuth.TokenURL == "" {
		return NewClientWithHTTPClient(cfg, &http.Client{Timeout: cfg.RequestTimeout})
	}

	oauthCfg := clientcredentials.Config{
		ClientID:     cfg.OAuth.ClientID,
		ClientSecret: cfg.OAuth.ClientSecret,
		TokenURL:     cfg.OAuth.TokenURL,
		Scopes:       cfg.OAuth.Scopes,
		AuthStyle:    oauth2.AuthStyleInHeader,
	}
	// oauth2.HTTPClient bounds the token fetch; the same budget is applied to
	// the returned client below so an unreachable token endpoint fails on the
	// same deadline as a slow AI answer instead of outliving it.
	tokenFetchCtx := context.WithValue(context.Background(), oauth2.HTTPClient, &http.Client{Timeout: cfg.RequestTimeout})
	httpClient := oauthCfg.Client(tokenFetchCtx)
	httpClient.Timeout = cfg.RequestTimeout
	return NewClientWithHTTPClient(cfg, httpClient)
}

// NewClientWithHTTPClient builds a Client using httpClient directly. This is
// intended for tests, where httpClient is typically an httptest.Server's
// client, but is also how NewClient assembles the production client.
func NewClientWithHTTPClient(cfg config.AIAgentConfig, httpClient *http.Client) *Client {
	return &Client{
		baseURL:    cfg.ServiceURL,
		httpClient: httpClient,
	}
}

// RetrieveMatches fetches recommended matches for the caller via
// POST {aiServiceURL}/networking/recommend, body {}.
func (c *Client) RetrieveMatches(ctx context.Context, jwtAssertion string) ([]models.RecommendedUser, error) {
	var out []models.RecommendedUser
	if err := c.postJSON(ctx, "networking/recommend", jwtAssertion, struct{}{}, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving matches: %w", err)
	}
	return out, nil
}

// RetrieveO2BarRecommendations fetches O2Bar recommendations for the caller
// via POST {aiServiceURL}/o2bar/recommend. When question is nil, no
// request body is sent at all -- not even "{}" -- matching the old
// `question is string ? {question} : ()` exactly.
func (c *Client) RetrieveO2BarRecommendations(ctx context.Context, jwtAssertion string, question *string) ([]models.O2BarRecommendationResponse, error) {
	var body any
	if question != nil {
		body = map[string]string{"question": *question}
	}

	var out []models.O2BarRecommendationResponse
	if err := c.postJSONOrNoBody(ctx, "o2bar/recommend", jwtAssertion, body, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving O2Bar recommendations: %w", err)
	}
	return out, nil
}

// SendProfileInfo forwards profile to the external AI agent service via
// POST {aiServiceURL}/profile/create, body
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

	req, err := c.newRequest(ctx, "profile/create", jwtAssertion, bytes.NewReader(b))
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
// recommendations via POST {aiServiceURL}/agenda/create, body {}.
// The external service returns fully-formed session objects itself -- no DB
// enrichment happens here.
func (c *Client) RetrieveAgendaRecommendations(ctx context.Context, jwtAssertion string) ([]models.PickedForYouSession, error) {
	var out []models.PickedForYouSession
	if err := c.postJSON(ctx, "agenda/create", jwtAssertion, struct{}{}, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving agenda recommendations: %w", err)
	}
	return out, nil
}

// RetrieveChatResponse forwards req to the external AI agent service via
// POST {aiServiceURL}/assistant/chat, body = the whole request.
func (c *Client) RetrieveChatResponse(ctx context.Context, jwtAssertion string, req models.ChatRequest) (*models.ChatResponse, error) {
	var out models.ChatResponse
	if err := c.postJSON(ctx, "assistant/chat", jwtAssertion, req, &out); err != nil {
		return nil, fmt.Errorf("aiagent: retrieving chat response: %w", err)
	}
	return &out, nil
}

// postJSON sends body (always JSON-encoded, even if empty) and decodes the
// response into out.
func (c *Client) postJSON(ctx context.Context, path, jwtAssertion string, body, out any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("encoding request body: %w", err)
	}
	return c.doJSON(ctx, path, jwtAssertion, bytes.NewReader(b), out)
}

// postJSONOrNoBody sends body JSON-encoded, or no request body at all when
// body is nil, and decodes the response into out.
func (c *Client) postJSONOrNoBody(ctx context.Context, path, jwtAssertion string, body, out any) error {
	if body == nil {
		return c.doJSON(ctx, path, jwtAssertion, nil, out)
	}
	return c.postJSON(ctx, path, jwtAssertion, body, out)
}

func (c *Client) doJSON(ctx context.Context, path, jwtAssertion string, bodyReader io.Reader, out any) error {
	req, err := c.newRequest(ctx, path, jwtAssertion, bodyReader)
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
		return &StatusError{StatusCode: resp.StatusCode, URL: req.URL.String(), Body: string(errBody)}
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decoding response body: %w", err)
	}
	return nil
}

func (c *Client) newRequest(ctx context.Context, path, jwtAssertion string, bodyReader io.Reader) (*http.Request, error) {
	reqURL, err := url.JoinPath(c.baseURL, path)
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
