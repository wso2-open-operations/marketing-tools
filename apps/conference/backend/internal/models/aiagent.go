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

// Package models' AI-feature types mirror the old Ballerina ai_agent
// module's records (see .claude/PLAN.md). Ballerina's open records (the
// "json...;" rest field, tolerating/passing through arbitrary extra JSON)
// are dropped in favor of plain closed Go structs -- a deliberate
// simplification, not an oversight; no known consumer depends on any extra
// field today.
package models

// RecommendedUser is the raw response item from the external matchmaking
// service's POST /networking/recommend endpoint.
type RecommendedUser struct {
	Email   string   `json:"email"`
	Name    string   `json:"name"`
	Company string   `json:"company"`
	Title   string   `json:"title"`
	Reason  string   `json:"reason"`
	Tags    []string `json:"tags"`
}

// MatchedUser is a RecommendedUser enriched with this service's own
// uuid/profileUrl via an attendee-by-email lookup. ProfileURL is absent
// entirely (not null) when the lookup found no attendee or the attendee has
// none, matching the old record's optional (not nilable) profileUrl field.
type MatchedUser struct {
	UUID       string   `json:"uuid"`
	Name       string   `json:"name"`
	Company    string   `json:"company"`
	Title      string   `json:"title"`
	Reason     string   `json:"reason"`
	Tags       []string `json:"tags"`
	ProfileURL *string  `json:"profileUrl,omitempty"`
}

// O2BarRecommendationInput is the payload for POST /o2bar/recommendations.
// Question is nil (not sent at all, not sent as "") when the caller omits
// it -- the external client must send no request body at all in that case,
// matching the old `question is string ? {question} : ()` exactly (see
// .claude/PLAN.md and internal/clients/aiagent).
type O2BarRecommendationInput struct {
	Question *string `json:"question,omitempty"`
}

// O2BarTimeSlot is one entry of an O2Bar recommendation's availableTimeSlots.
type O2BarTimeSlot struct {
	StartTime string `json:"startTime"`
	EndTime   string `json:"endTime"`
}

// O2BarRecommendationResponse is the raw response item from the external
// matchmaking service's POST /o2bar/recommend endpoint.
type O2BarRecommendationResponse struct {
	Email                string          `json:"email"`
	Name                 string          `json:"name"`
	Reason               string          `json:"reason"`
	RecommendedQuestions []string        `json:"recommendedQuestions"`
	AvailableTimeSlots   []O2BarTimeSlot `json:"availableTimeSlots"`
	ProfileURL           *string         `json:"profileUrl,omitempty"`
}

// O2BarRecommendation is an O2BarRecommendationResponse enriched with this
// service's own uuid via an attendee-by-email lookup. Unlike MatchedUser,
// ProfileURL prefers the AI response's own value, only falling back to the
// DB attendee's profileUrl if the AI response didn't include one -- a
// different merge rule from matches (see .claude/PLAN.md).
type O2BarRecommendation struct {
	UUID                 string          `json:"uuid"`
	Name                 string          `json:"name"`
	Email                string          `json:"email"`
	ProfileURL           *string         `json:"profileUrl,omitempty"`
	Reason               string          `json:"reason"`
	RecommendedQuestions []string        `json:"recommendedQuestions"`
	AvailableTimeSlots   []O2BarTimeSlot `json:"availableTimeSlots"`
}

// PersonalizeAgentUserProfile is the payload for POST /users/profile,
// forwarded to the external personalize agent service raw (see
// .claude/PLAN.md) -- the response is passed through untouched too, so
// there is no corresponding response type.
type PersonalizeAgentUserProfile struct {
	Company      string `json:"company"`
	Country      string `json:"country"`
	Email        string `json:"email"`
	LinkedInInfo string `json:"linkedInInfo"`
	Name         string `json:"name"`
	Title        string `json:"title"`
}

// PickedForYouLocation is a PickedForYouSession's location detail.
type PickedForYouLocation struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Address      string `json:"address"`
	FloorPlanURL string `json:"floorPlanUrl"`
}

// PickedForYouVenue is a PickedForYouSession's venue detail.
type PickedForYouVenue struct {
	ID             int    `json:"id"`
	Name           string `json:"name"`
	GeoCoordinates string `json:"geoCoordinates"`
}

// PickedForYouAgenda is a PickedForYouSession's agenda detail.
type PickedForYouAgenda struct {
	ID      int    `json:"id"`
	EventID int    `json:"eventId"`
	Name    string `json:"name"`
	Date    string `json:"date"`
}

// PickedForYouSessionSpeaker is one speaker entry on a PickedForYouSession.
type PickedForYouSessionSpeaker struct {
	ID        int    `json:"id"`
	SpeakerID string `json:"speakerId"`
	SessionID int    `json:"sessionId"`
}

// PickedForYouSession is one fully-formed session recommendation returned
// directly by the external picked-for-you service, with no DB enrichment
// at all (see .claude/PLAN.md). YoutubeLink/SlidesLink/PDFLink are nilable
// but always-present fields (never omitted), matching the old `string?`
// (not `string?`-optional) Ballerina fields.
type PickedForYouSession struct {
	ID                      string                       `json:"id"`
	Title                   string                       `json:"title"`
	Description             string                       `json:"description"`
	Category                string                       `json:"category"`
	StartTime               string                       `json:"startTime"`
	EndTime                 string                       `json:"endTime"`
	IsFeedbackNotified      bool                         `json:"isFeedbackNotified"`
	LocationID              string                       `json:"locationId"`
	VenueID                 string                       `json:"venueId"`
	AgendaID                int                          `json:"agendaId"`
	YoutubeLink             *string                      `json:"youtubeLink"`
	SlidesLink              *string                      `json:"slidesLink"`
	PDFLink                 *string                      `json:"pdfLink"`
	Location                PickedForYouLocation         `json:"location"`
	Venue                   PickedForYouVenue            `json:"venue"`
	Agenda                  PickedForYouAgenda           `json:"agenda"`
	SessionSpeakers         []PickedForYouSessionSpeaker `json:"sessionSpeakers"`
	SessionSponsors         []any                        `json:"sessionSponsors"`
	PersonalizedDescription string                       `json:"personalizedDescription"`
}

// ChatHistory is one prior question/answer pair in a ChatRequest.
type ChatHistory struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

// ChatRequest is the payload for POST /assistant/chat, forwarded to the
// external chat service as-is (whole request body, see .claude/PLAN.md).
type ChatRequest struct {
	History  []ChatHistory `json:"history"`
	Question string        `json:"question"`
}

// ChatResponse is the external chat service's response, returned as-is.
type ChatResponse struct {
	Response    string   `json:"response"`
	Suggestions []string `json:"suggestions"`
}

// AIFeatureStatus is the JSON-shaped mirror of config.AIFeatureStatus,
// returned verbatim by GET /ai-maintenance-status.
type AIFeatureStatus struct {
	EnabledChatAssistant      bool `json:"enabledChatAssistant"`
	EnabledPersonalizedAgenda bool `json:"enabledPersonalizedAgenda"`
	EnabledMatchMaker         bool `json:"enabledMatchMaker"`
	EnabledO2Bar              bool `json:"enabledO2Bar"`
}
