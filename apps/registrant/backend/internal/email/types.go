// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package email

// OAuth2Config holds the client-credentials grant configuration used to
// authenticate against the email service.
type OAuth2Config struct {
	TokenURL     string
	ClientID     string
	ClientSecret string
}

// ServiceConfig configures the email service client.
type ServiceConfig struct {
	Endpoint string
	OAuth    OAuth2Config
	From     string
}

// Payload is the request body sent to the email service's send-email
// endpoint. Template must be base64-encoded HTML — see BindKeyValues.
type Payload struct {
	To       []string `json:"to"`
	From     string   `json:"from"`
	Subject  string   `json:"subject"`
	Template string   `json:"template"`
}
