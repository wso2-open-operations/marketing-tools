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

import "strings"

// Notification title/body length bounds. These are not ours to pick: they
// mirror the caps the downstream wso2con handler in push-notification-service
// enforces (maxTitleBytes 200, maxBodyBytes 1000), which exist to keep the
// assembled FCM message under FCM's 4 KB payload limit.
//
// The unit is BYTES, not runes, because that is what FCM counts and what the
// downstream check uses -- Go's len() on a string is a byte count. Measuring
// runes here was a real defect: a 1024-rune description sailed past this
// validation and was rejected downstream (1024 > 1000), and any non-ASCII text
// blew the byte cap far below the rune cap (a 200-rune Sinhala title is ~600
// bytes). Every value let past here becomes a downstream failure the admin
// sees as a 500 on a body this API just told them was fine, so the two caps
// have to agree exactly. If push-notification-service moves its constants,
// move these with them.
//
// The frontend caps tighter (50/200) in its own form; these stay at the
// service-side limits so a stricter client is never the thing that makes a
// valid request fail.
const (
	NotificationTitleMaxBytes = 200
	NotificationBodyMaxBytes  = 1000
)

// UserNotificationRequest is the payload for POST /users/notifications.
// Field names match what the frontend already sends verbatim.
type UserNotificationRequest struct {
	Title       string `json:"title"`
	Description string `json:"description"`
}

// Validate trims the request in place and reports the first problem with it,
// or an empty string when it is valid. Trimming here rather than in the
// handler keeps "what counts as empty" in one place: a title of only spaces
// is a missing title, not a 200-char-valid one.
//
// Lengths count bytes, not runes, so that a request this accepts is one the
// downstream notification service will also accept -- see the constants above.
// Non-ASCII text therefore fits fewer characters than the byte limit suggests,
// which is the downstream (and FCM's) reality rather than something this
// validation is free to be generous about.
func (r *UserNotificationRequest) Validate() string {
	r.Title = strings.TrimSpace(r.Title)
	r.Description = strings.TrimSpace(r.Description)

	switch {
	case r.Title == "":
		return "title is required"
	case len(r.Title) > NotificationTitleMaxBytes:
		return "title exceeds the maximum length"
	case len(r.Description) > NotificationBodyMaxBytes:
		return "description exceeds the maximum length"
	default:
		return ""
	}
}
