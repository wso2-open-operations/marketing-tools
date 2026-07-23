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

// FeedbackType mirrors the old Ballerina FeedbackType enum.
type FeedbackType string

const (
	FeedbackSession FeedbackType = "SESSION"
	FeedbackEvent   FeedbackType = "EVENT"
)

// IsValid reports whether t is one of the defined feedback types.
func (t FeedbackType) IsValid() bool {
	switch t {
	case FeedbackSession, FeedbackEvent:
		return true
	default:
		return false
	}
}

// FeedbackRequest is the payload for POST /feedback.
type FeedbackRequest struct {
	SessionID    *string      `json:"sessionId,omitempty"`
	Rating       int          `json:"rating"`
	Comment      *string      `json:"comment,omitempty"`
	FeedbackType FeedbackType `json:"feedbackType"`
}

// FeedbackInsert is what gets written to the feedback table.
type FeedbackInsert struct {
	UserUUID     string
	FeedbackType FeedbackType
	SessionID    *string
	EventID      *string
	Rating       int
	Comment      *string
}
