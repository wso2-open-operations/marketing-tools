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

package models

import "time"

// AppConfig is one row of the app_config table -- an opaque key/value
// operational config store, not a theme/feature-flag system (see
// .claude/PLAN.md). GET /app-configs returns every row verbatim regardless
// of what any given key means.
type AppConfig struct {
	Key       string    `json:"key"`
	Value     string    `json:"value"`
	CreatedBy string    `json:"createdBy"`
	CreatedOn time.Time `json:"createdOn"`
	UpdatedBy string    `json:"updatedBy"`
	UpdatedOn time.Time `json:"updatedOn"`
}
