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

// Package features is the single source of truth for which parts of the
// attendee microapp can be switched off, what they are called when they are,
// and which HTTP routes stop answering.
//
// The store is the existing app_config table -- three rows per feature:
//
//	is_<feature>_enabled            "1" | "0"
//	<feature>_coming_soon_title     free text shown on the placeholder screen
//	<feature>_coming_soon_message   free text shown under the title
//
// `is_<feature>_enabled` is not a new convention: is_agenda_enabled,
// is_speakers_enabled, is_networking_enabled, is_ai_chat_enabled and
// is_attendee_list_enabled were already live in the database before this
// package existed, and this package adopts their spelling rather than
// migrating them. Everything is snake_case, matching what openapi.yaml
// asserts about stored keys.
//
// Every field has a compiled-in default, so an empty app_config table, an
// unseeded environment or an outright database failure all degrade to a
// working app rather than a blank one. A row only ever *overrides* a default;
// it can never introduce a feature this file does not already know about.
//
// The same list is mirrored by hand in the microapp at
// src/services/types/config.ts. Nothing enforces that the two agree -- adding
// a feature here means adding it there in the same change.
package features

// Feature is the stable identifier for one gateable part of the microapp. The
// value is the snake_case stem used to build every app_config key for that
// feature, so renaming one orphans its rows in the database.
type Feature string

const (
	// Agenda is the agenda browser: the day/track grid and the event list
	// behind it. Off, the microapp still needs an event to resolve
	// timezone and current-event context, so /events/current stays open --
	// see the routes table in cmd/server/main.go.
	Agenda Feature = "agenda"
	// SessionDetails is the single-session screen reached from the agenda.
	// Independent of Agenda: an agenda that browses but does not drill in
	// is a valid configuration during content freeze.
	SessionDetails Feature = "session_details"
	// Speakers is the speaker directory and its search.
	Speakers Feature = "speakers"
	// SpeakerDetails is the single-speaker profile screen.
	SpeakerDetails Feature = "speaker_details"
	// AgendaRecommendations is "Picked for You" -- the AI-personalised
	// agenda. Default off: it is one of the AI screens.
	AgendaRecommendations Feature = "agenda_recommendations"
	// Networking is the connections graph: requests, accepts, removals.
	// Default off.
	Networking Feature = "networking"
	// AttendeeList is attendee search and browse, which the networking
	// screens build on but which can also be shown alone.
	AttendeeList Feature = "attendee_list"
	// AttendeeRecommendations is AI matchmaking -- suggested people to
	// meet. Default off: AI screen.
	AttendeeRecommendations Feature = "attendee_recommendations"
	// AIChat is the conference assistant chat. Default off: AI screen.
	AIChat Feature = "ai_chat"
	// O2Bar is the AI engineer-recommendation flow for the O2 bar.
	// Default off: AI screen.
	O2Bar Feature = "o2bar"
	// PersonalizedProfile is the AI profile-enrichment call that the
	// networking and matchmaking screens use to build a richer profile.
	// Default off: AI screen.
	PersonalizedProfile Feature = "personalized_profile"
	// Activities is the non-session activity list (parties, workshops).
	Activities Feature = "activities"
	// Feedback is post-session feedback submission.
	Feedback Feature = "feedback"
	// Favorites is starring sessions into a personal schedule.
	Favorites Feature = "favorites"
	// Shop is the WSO2 Coin shop: catalog, checkout, order history.
	Shop Feature = "shop"
	// Wallet is the coin balance and transaction history.
	Wallet Feature = "wallet"
	// Coin is earning coins: QR scanning, scan history, scan summary.
	Coin Feature = "coin"
	// Leaderboard is the coin leaderboard and its opt-out preference.
	Leaderboard Feature = "leaderboard"
	// Notifications is the admin broadcast push route.
	Notifications Feature = "notifications"
	// QRCode is the attendee's own badge QR. It has no route on this
	// backend -- the microapp fetches it from the auth service -- but it
	// is a screen the microapp can hide, so it carries a flag here so that
	// every feature is toggled from one table.
	QRCode Feature = "qr_code"
	// Profile is the attendee's own profile screen. It has no gated route
	// either: /attendees/me and /user-profile are how the app learns who
	// is holding it, and gating them would brick the shell rather than
	// hide a screen.
	Profile Feature = "profile"
	// MeetFDE is the "meet a field engineer" segment of the networking
	// screen. Its content is a hardcoded list in the microapp, so there is
	// nothing to gate here -- the flag only hides the segment.
	MeetFDE Feature = "meet_fde"
	// AttendeeRegistration is on-site session registration. It calls the
	// separate registration backend, not this service, so the flag is
	// advisory here.
	AttendeeRegistration Feature = "attendee_registration"
	// FloorPlan is the venue map screen. Static assets in the microapp,
	// no route here.
	FloorPlan Feature = "floor_plan"
	// SessionNotes is the per-session private notes the microapp keeps in
	// local storage. No route here.
	SessionNotes Feature = "session_notes"
	// SessionNotifications is the attendee's own session-reminder
	// preferences screen, scheduled on the device. No route here.
	SessionNotifications Feature = "session_notifications"
)

// Definition is everything this service knows about one feature when no
// database row exists for it.
type Definition struct {
	// Feature is the identifier, repeated here so a Definition is
	// self-describing once pulled out of the registry.
	Feature Feature
	// EnabledByDefault is the value used when is_<feature>_enabled is
	// missing or unparseable. AI screens and networking are false; every
	// other feature is true, so an empty app_config table yields the
	// pre-flag behaviour of the app.
	EnabledByDefault bool
	// DefaultTitle and DefaultMessage are the placeholder copy used when
	// the feature is off and no override row exists.
	DefaultTitle   string
	DefaultMessage string
	// Gated is false for features with no route on this backend (or whose
	// routes must keep answering for the app shell to work). A false here
	// means the flag is advisory: the microapp hides the screen, the API
	// does not change behaviour.
	Gated bool
}

// EnabledKey is the app_config row that turns the feature on or off.
func (f Feature) EnabledKey() string { return "is_" + string(f) + "_enabled" }

// TitleKey is the app_config row overriding the placeholder heading.
func (f Feature) TitleKey() string { return string(f) + "_coming_soon_title" }

// MessageKey is the app_config row overriding the placeholder body copy.
func (f Feature) MessageKey() string { return string(f) + "_coming_soon_message" }

// definitions is the registry, in the order the keys are seeded by
// migrations/015_feature_flags.sql. Keep the two in step.
var definitions = []Definition{
	{
		Feature:          Agenda,
		EnabledByDefault: true,
		DefaultTitle:     "Agenda coming soon",
		DefaultMessage:   "The full conference agenda will appear here as soon as it is published.",
		Gated:            true,
	},
	{
		Feature:          SessionDetails,
		EnabledByDefault: true,
		DefaultTitle:     "Session details coming soon",
		DefaultMessage:   "Full session write-ups are still being finalised. Check back shortly.",
		Gated:            true,
	},
	{
		Feature:          Speakers,
		EnabledByDefault: true,
		DefaultTitle:     "Speakers coming soon",
		DefaultMessage:   "The speaker line-up is still being confirmed. Check back shortly.",
		Gated:            true,
	},
	{
		Feature:          SpeakerDetails,
		EnabledByDefault: true,
		DefaultTitle:     "Speaker profiles coming soon",
		DefaultMessage:   "Speaker profiles are still being finalised. Check back shortly.",
		Gated:            true,
	},
	{
		Feature:          AgendaRecommendations,
		EnabledByDefault: false,
		DefaultTitle:     "Picked for You is coming soon",
		DefaultMessage:   "Personalised session recommendations will be available closer to the event.",
		Gated:            true,
	},
	{
		Feature:          Networking,
		EnabledByDefault: false,
		DefaultTitle:     "Networking is coming soon",
		DefaultMessage:   "Connecting with other attendees will open closer to the event.",
		Gated:            true,
	},
	{
		Feature:          AttendeeList,
		EnabledByDefault: true,
		DefaultTitle:     "Attendee directory coming soon",
		DefaultMessage:   "The attendee directory will open closer to the event.",
		Gated:            true,
	},
	{
		Feature:          AttendeeRecommendations,
		EnabledByDefault: false,
		DefaultTitle:     "Suggested connections are coming soon",
		DefaultMessage:   "We will suggest people worth meeting once the attendee list is final.",
		Gated:            true,
	},
	{
		Feature:          AIChat,
		EnabledByDefault: false,
		DefaultTitle:     "The conference assistant is coming soon",
		DefaultMessage:   "Ask-me-anything about the conference opens closer to the event.",
		Gated:            true,
	},
	{
		Feature:          O2Bar,
		EnabledByDefault: false,
		DefaultTitle:     "O2 Bar is coming soon",
		DefaultMessage:   "Book time with a WSO2 engineer once the O2 Bar opens.",
		Gated:            true,
	},
	{
		Feature:          PersonalizedProfile,
		EnabledByDefault: false,
		DefaultTitle:     "Profile personalisation is coming soon",
		DefaultMessage:   "Richer profiles will be generated closer to the event.",
		Gated:            true,
	},
	{
		Feature:          Activities,
		EnabledByDefault: true,
		DefaultTitle:     "Activities coming soon",
		DefaultMessage:   "Side activities and social events will be listed here shortly.",
		Gated:            true,
	},
	{
		Feature:          Feedback,
		EnabledByDefault: true,
		DefaultTitle:     "Feedback is coming soon",
		DefaultMessage:   "Session feedback opens once the conference starts.",
		Gated:            true,
	},
	{
		Feature:          Favorites,
		EnabledByDefault: true,
		DefaultTitle:     "My schedule is coming soon",
		DefaultMessage:   "Saving sessions to your own schedule opens once the agenda is final.",
		Gated:            true,
	},
	{
		Feature:          Shop,
		EnabledByDefault: true,
		DefaultTitle:     "The shop is coming soon",
		DefaultMessage:   "Spend your WSO2 Coins here once the shop opens.",
		Gated:            true,
	},
	{
		Feature:          Wallet,
		EnabledByDefault: true,
		DefaultTitle:     "Your wallet is coming soon",
		DefaultMessage:   "Your WSO2 Coin balance will appear here once the event starts.",
		Gated:            true,
	},
	{
		Feature:          Coin,
		EnabledByDefault: true,
		DefaultTitle:     "Earning coins is coming soon",
		DefaultMessage:   "Scan QR codes around the venue to earn WSO2 Coins once the event starts.",
		Gated:            true,
	},
	{
		Feature:          Leaderboard,
		EnabledByDefault: true,
		DefaultTitle:     "The leaderboard is coming soon",
		DefaultMessage:   "See how you rank once coin collecting opens.",
		Gated:            true,
	},
	{
		Feature:          Notifications,
		EnabledByDefault: true,
		DefaultTitle:     "Notifications are coming soon",
		DefaultMessage:   "Announcements will be delivered here during the conference.",
		Gated:            true,
	},
	{
		// No route on this backend: the badge QR comes from the auth
		// service, so this flag only hides the screen.
		Feature:          QRCode,
		EnabledByDefault: true,
		DefaultTitle:     "Your badge is coming soon",
		DefaultMessage:   "Your check-in QR code will appear here closer to the event.",
		Gated:            false,
	},
	{
		// Deliberately ungated: /attendees/me and /user-profile are how
		// the shell identifies the attendee. Gating them would break the
		// app rather than hide a screen.
		Feature:          Profile,
		EnabledByDefault: true,
		DefaultTitle:     "Your profile is coming soon",
		DefaultMessage:   "Profile settings will be available closer to the event.",
		Gated:            false,
	},
	{
		Feature:          MeetFDE,
		EnabledByDefault: true,
		DefaultTitle:     "Meet a Field Engineer is coming soon",
		DefaultMessage:   "Booking time with a WSO2 field engineer opens closer to the event.",
		Gated:            false,
	},
	{
		// Calls the separate registration backend, so nothing on this
		// service enforces it.
		Feature:          AttendeeRegistration,
		EnabledByDefault: true,
		DefaultTitle:     "Session registration is coming soon",
		DefaultMessage:   "Reserving your seat in a session opens closer to the event.",
		Gated:            false,
	},
	{
		Feature:          FloorPlan,
		EnabledByDefault: true,
		DefaultTitle:     "The venue map is coming soon",
		DefaultMessage:   "Floor plans will be published closer to the event.",
		Gated:            false,
	},
	{
		Feature:          SessionNotes,
		EnabledByDefault: true,
		DefaultTitle:     "Session notes are coming soon",
		DefaultMessage:   "Taking private notes on a session opens once the agenda is final.",
		Gated:            false,
	},
	{
		Feature:          SessionNotifications,
		EnabledByDefault: true,
		DefaultTitle:     "Session reminders are coming soon",
		DefaultMessage:   "Reminders before your saved sessions open once the agenda is final.",
		Gated:            false,
	},
}

// All returns every known feature definition in registry order. The returned
// slice is a copy; mutating it does not affect the registry.
func All() []Definition {
	out := make([]Definition, len(definitions))
	copy(out, definitions)
	return out
}

// byFeature indexes the registry for Lookup. Built once at init because the
// registry is immutable after compilation.
var byFeature = func() map[Feature]Definition {
	m := make(map[Feature]Definition, len(definitions))
	for _, d := range definitions {
		m[d.Feature] = d
	}
	return m
}()

// Lookup returns the definition for f, and whether f is a known feature.
func Lookup(f Feature) (Definition, bool) {
	d, ok := byFeature[f]
	return d, ok
}
