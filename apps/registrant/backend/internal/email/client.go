// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package email

import (
	"context"
	"net/http"
	"strings"

	"golang.org/x/oauth2/clientcredentials"
)

// Client sends emails via the configured email service, authenticating with
// an OAuth2 client-credentials grant (token fetched lazily on first request
// and cached/refreshed by the underlying oauth2 transport).
type Client struct {
	httpClient *http.Client
	endpoint   string
	from       string
}

func NewClient(cfg ServiceConfig) *Client {
	oauthCfg := clientcredentials.Config{
		ClientID:     cfg.OAuth.ClientID,
		ClientSecret: cfg.OAuth.ClientSecret,
		TokenURL:     cfg.OAuth.TokenURL,
	}
	return newClient(cfg.Endpoint, cfg.From, oauthCfg.Client(context.Background()))
}

func newClient(endpoint, from string, httpClient *http.Client) *Client {
	return &Client{
		httpClient: httpClient,
		endpoint:   strings.TrimSuffix(endpoint, "/"),
		from:       from,
	}
}
