// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package handlers

import (
	"net/http"

	"attendee-registration/internal/middleware"

	"github.com/gin-gonic/gin"
)

const errUserInfoNotFound = "User information header not found"

// requireUserInfo mirrors each Ballerina resource function's re-fetch of the
// invoker's user info from the context set by the JWT interceptor: every
// handler checks it independently rather than trusting the middleware ran.
func requireUserInfo(c *gin.Context) (*middleware.UserInfo, bool) {
	userInfo := middleware.UserInfoFromContext(c.Request.Context())
	if userInfo == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"message": errUserInfoNotFound})
		return nil, false
	}
	return userInfo, true
}
