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
