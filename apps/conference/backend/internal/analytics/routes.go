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

package analytics

// This file is the answer to "which endpoints are worth tracking, and what does
// a call to each one actually mean?". It is the part of this package that has to
// be maintained: everything else is plumbing, this is judgement.
//
// # Why a skip list rather than an allow list
//
// New routes are tracked by default and land in Moesif tagged
// class="unclassified". The alternative — an allow list — fails silently in the
// worst possible way: someone adds an endpoint, nobody adds it here, and the
// dashboard reports that a shipped feature has no users. An unclassified event
// is visible and slightly untidy, which is a much better failure than an
// invisible one. Add the route to routeClasses when you notice the tag.
//
// # Why some endpoints are skipped
//
// The microapp is a React Query client, and several of its queries carry a
// refetchInterval. Those endpoints are timers, not features: their call count
// measures how long a tab was left open, and on a request-count chart they hide
// every conversion-shaped event underneath them. Per user, per hour, measured
// from the microapp's own hooks:
//
//	GET /qr/history            every 5s, mounted app-wide     ~720/hr
//	GET /qr/summary            every 5s, mounted app-wide      ~720/hr
//	GET /shops/items           every 15s while Shop is open   ~240/hr
//	GET /wallets/balances/me   every 15s while Shop is open   ~240/hr
//	GET /app-configs           every 15m, mounted app-wide       4/hr
//
// The first four are ~1,900 requests per user per hour between them. At
// conference scale that is a few hundred thousand events an hour that answer no
// question anyone asked, so they are skipped outright. Nothing is lost that
// cannot be recovered elsewhere: "did anyone open the shop" is answered by
// GET /shops/orders/me, which the Shop screen also fetches on mount but without
// a timer, and "did anyone earn coins" is answered by POST /qr/scan, the only
// endpoint in that group that represents an action rather than a redraw.
//
// GET /app-configs is skipped for a different reason. It is cheap, but it is the
// freshness-beacon poll — the agenda/speakers/attendees "last updated at" rows —
// and its count is a pure function of how long the app was open. GET
// /attendees/me is kept as the app-open heartbeat instead, because it is the
// same signal with a name that will not later be mistaken for content activity.
//
// # Why the agenda, speaker and attendee list endpoints are NOT skipped
//
// The instinct to skip them along with the beacon poll is understandable but
// backwards, because the beacon's conditional-refetch half was never wired up.
// The microapp fetches the beacon rows into its config store and does nothing
// with them: there is no comparison against a previous value and no
// invalidation keyed off them anywhere in the frontend. What actually refreshes
// those three lists is a 30-minute staleTime plus an explicit pull-to-refresh,
// with refetchOnWindowFocus disabled app-wide. So none of them is on a timer,
// and their call counts are low and meaningful.
//
// They are, however, meaningful as *screen opens*, not as feature engagement,
// and the distinction is the whole reason Class exists:
//
//   - GET /speakers is one app-wide fetch that also feeds the agenda-detail
//     join, so it fires even when nobody opens the Speakers tab. Its count is a
//     cold-start count. GET /speakers/:id is the real "used the speaker
//     directory" signal.
//   - GET /event-agendas is fetched when the Agenda screen mounts, and Agenda is
//     the default tab, so its count is also close to a cold-start count.
//     GET /events/:eventId/agendas (day switch, previous-event browse) and
//     GET /sessions/:id (tapped a session) are the real agenda-engagement
//     signals.
//   - POST /attendees/search is genuine intent, but one directory browse issues
//     many requests (debounced typing plus a cursor-paginated crawl), so count
//     distinct users rather than requests.
//
// Filter on class=intent to answer "is this feature being used". Include
// class=screen to answer "did anyone reach this screen". That is a better
// outcome than dropping the endpoints, which would have made both questions
// unanswerable.
//
// # A note on 304s
//
// Ten read endpoints carry middleware.ETag, so some of their events are
// bodiless 304 revalidations rather than content deliveries. Both are real
// client requests and both are recorded; Moesif has the status code, so split on
// it in the dashboard rather than expecting this file to have pre-filtered.

// Class says what a call to an endpoint means, which is not the same question as
// which endpoint was called. Without it, a request-count chart silently treats
// "an attendee asked the AI a question" and "a mounted component refetched" as
// the same event.
type Class string

const (
	// ClassIntent is a deliberate user action: a tap, a submit, a scan, a
	// question typed into the AI. One event is one decision by one attendee.
	// This is the class that answers "is this feature used".
	ClassIntent Class = "intent"

	// ClassScreen fires because a screen mounted or the app booted. It is a
	// reasonable proxy for "somebody got as far as this screen", and a poor
	// proxy for engagement: the microapp fetches several of these regardless of
	// which tab the user actually chose.
	ClassScreen Class = "screen"

	// ClassHeartbeat is on a timer and means only "the app is open". Kept
	// deliberately and in exactly one place (GET /attendees/me, every five
	// minutes) because session length and daily actives are worth knowing and
	// there is no client-side analytics SDK to ask instead.
	ClassHeartbeat Class = "heartbeat"

	// ClassUnclassified marks a route this file has not been taught about yet.
	// Seeing it in Moesif means a route was added and this table was not
	// updated — the event is still recorded, which is the point.
	ClassUnclassified Class = "unclassified"
)

// Feature names. These are the product areas a stakeholder would recognise, so
// that "is the shop being used" is one group-by rather than a remembered list of
// four route templates.
const (
	FeatureAgenda        = "agenda"
	FeatureSpeakers      = "speakers"
	FeatureActivities    = "activities"
	FeatureAttendees     = "attendees"
	FeatureNetworking    = "networking"
	FeatureFavorites     = "favorites"
	FeatureFeedback      = "feedback"
	FeatureAIAgent       = "ai-agent"
	FeatureShop          = "shop"
	FeatureCoin          = "coin"
	FeatureNotifications = "notifications"
	FeatureLeaderboard   = "leaderboard"
)

// RouteInfo is what the policy knows about one method-and-route pair.
type RouteInfo struct {
	Feature string
	Class   Class
}

// skippedRoutes are the endpoints that are never recorded, keyed by
// "METHOD /route-template". See the file comment for the reasoning behind each
// one; the short version is that every entry here is a timer or a probe.
var skippedRoutes = map[string]struct{}{
	// Kubernetes/load-balancer liveness and readiness probes. Not a client.
	"GET /health": {},

	// 5-second polls, mounted app-wide by the microapp's MainLayout. POST
	// /qr/scan carries the actual coin-earning signal.
	"GET /qr/history": {},
	"GET /qr/summary": {},

	// 15-second polls while the Shop tab is mounted. GET /shops/orders/me is
	// the un-timed mount fetch that stands in for "opened the shop".
	"GET /shops/items":         {},
	"GET /wallets/balances/me": {},

	// The freshness-beacon poll. GET /attendees/me is the kept heartbeat.
	"GET /app-configs": {},
}

// routeClasses maps "METHOD /route-template" onto its product meaning. Route
// templates must match cmd/server/main.go exactly, including Gin's ":param"
// spelling, because the lookup key is gin.Context.FullPath().
var routeClasses = map[string]RouteInfo{
	// Agenda. The bulk fetches mount with the Agenda tab, which is the app's
	// default tab; the parameterised ones require a choice.
	"GET /event-agendas":           {FeatureAgenda, ClassScreen},
	"GET /events":                  {FeatureAgenda, ClassScreen},
	"GET /events/current":          {FeatureAgenda, ClassScreen},
	"GET /events/:eventId/agendas": {FeatureAgenda, ClassIntent},
	"GET /sessions/current":        {FeatureAgenda, ClassScreen},
	"GET /sessions/:id":            {FeatureAgenda, ClassIntent},

	// Speakers. The list is an app-wide bootstrap fetch that also feeds the
	// agenda-detail join; only the detail view implies someone browsed.
	"GET /speakers":     {FeatureSpeakers, ClassScreen},
	"GET /speakers/:id": {FeatureSpeakers, ClassIntent},

	// Activities. Single caller, and its query uses staleTime 0, so this is a
	// clean 1:1 proxy for "opened the General tab".
	"GET /activities": {FeatureActivities, ClassScreen},

	// Attendee's own profile. The 5-minute heartbeat, and the only route in
	// this table whose count measures time rather than behaviour.
	"GET /attendees/me": {FeatureAttendees, ClassHeartbeat},
	"GET /user-profile": {FeatureAttendees, ClassScreen},
	"POST /attendees":   {FeatureAttendees, ClassIntent},
	"PATCH /attendees":  {FeatureAttendees, ClassIntent},

	// Networking. The search POST is intent but fans out into many requests per
	// browse, so count distinct users on it, not events.
	"POST /attendees/search":    {FeatureNetworking, ClassIntent},
	"GET /users/me/connections": {FeatureNetworking, ClassScreen},
	// Send a request, accept one, and withdraw/decline/remove one. Three
	// separate decisions, so three separate intents rather than one bucket.
	"POST /users/me/connections":            {FeatureNetworking, ClassIntent},
	"POST /users/me/connections/:id/accept": {FeatureNetworking, ClassIntent},
	"DELETE /users/me/connections/:id":      {FeatureNetworking, ClassIntent},

	// Favourites. Served but currently clientless — the microapp keeps
	// favourites locally. Tracked anyway, because the day the frontend adopts
	// these routes the first thing anyone will ask is whether it worked.
	"GET /users/me/favorites":               {FeatureFavorites, ClassScreen},
	"PUT /users/me/favorites/:sessionId":    {FeatureFavorites, ClassIntent},
	"DELETE /users/me/favorites/:sessionId": {FeatureFavorites, ClassIntent},

	// Feedback. One event per submitted form: the cleanest signal on the whole
	// surface.
	"POST /feedback": {FeatureFeedback, ClassIntent},

	// AI agent. The POSTs are one-per-question and are the point of the
	// feature; the GETs mount with their screens.
	"POST /assistant/chat":        {FeatureAIAgent, ClassIntent},
	"POST /o2bar/recommendations": {FeatureAIAgent, ClassIntent},
	"GET /o2bar/recommendations":  {FeatureAIAgent, ClassScreen},
	"POST /users/profile":         {FeatureAIAgent, ClassIntent},
	"GET /agenda/recommendations": {FeatureAIAgent, ClassScreen},
	"GET /users/me/matches":       {FeatureAIAgent, ClassScreen},
	"GET /ai-maintenance-status":  {FeatureAIAgent, ClassScreen},

	// Shop. checkout then checkout/confirm is a funnel, and orders/me is the
	// stand-in for "opened the shop" now that the two polled shop reads are
	// skipped. Note that confirm answers 409 on a replay by design, so a 409
	// here is expected traffic rather than a fault.
	"GET /shops/orders/me":         {FeatureShop, ClassScreen},
	"POST /shops/checkout":         {FeatureShop, ClassIntent},
	"POST /shops/checkout/confirm": {FeatureShop, ClassIntent},

	// Coin. POST /qr/scan is the only earn action; the two polled reads around
	// it are skipped. GET /qr-codes is the organiser-side list of generated
	// codes, fetched when that screen mounts and not on a timer.
	"POST /qr/scan": {FeatureCoin, ClassIntent},
	"GET /qr-codes": {FeatureCoin, ClassScreen},

	// Leaderboard. The board itself mounts with its screen; the preferences PUT
	// is the opt-in/opt-out decision, which is the number worth watching.
	"GET /leaderboard":             {FeatureLeaderboard, ClassScreen},
	"GET /leaderboard/preferences": {FeatureLeaderboard, ClassScreen},
	"PUT /leaderboard/preferences": {FeatureLeaderboard, ClassIntent},

	// Admin broadcast. Single-digit volume, but the one endpoint where knowing
	// exactly how many times it fired matters.
	"POST /users/notifications": {FeatureNotifications, ClassIntent},
}

// RoutePolicy decides whether a route is recorded and what it means. It holds no
// state beyond its two tables and is safe to share across goroutines.
type RoutePolicy struct {
	skipped map[string]struct{}
	classes map[string]RouteInfo
}

// DefaultRoutePolicy returns the policy described by this file.
func DefaultRoutePolicy() RoutePolicy {
	return RoutePolicy{skipped: skippedRoutes, classes: routeClasses}
}

// NewRoutePolicy builds a policy from explicit tables. It exists for tests and
// for a deployment that needs to suppress one more endpoint without a code
// change to the default; production wiring uses DefaultRoutePolicy.
func NewRoutePolicy(skipped map[string]struct{}, classes map[string]RouteInfo) RoutePolicy {
	if skipped == nil {
		skipped = map[string]struct{}{}
	}
	if classes == nil {
		classes = map[string]RouteInfo{}
	}
	return RoutePolicy{skipped: skipped, classes: classes}
}

// Lookup reports what to do with one request. method is the HTTP verb and route
// is the Gin route template (gin.Context.FullPath()), e.g.
// Lookup("GET", "/sessions/:id").
//
// The second return value is false when the route must not be recorded at all.
// An unknown route is recorded, not skipped — see the file comment.
func (p RoutePolicy) Lookup(method, route string) (RouteInfo, bool) {
	// A request that matched no route has an empty template. Those are almost
	// entirely internet background noise against a public Choreo endpoint —
	// scanners probing /wp-login.php and friends — and recording them would
	// bury real 4xx signal under it.
	if route == "" {
		return RouteInfo{}, false
	}

	key := method + " " + route
	if _, skip := p.skipped[key]; skip {
		return RouteInfo{}, false
	}
	if info, ok := p.classes[key]; ok {
		return info, true
	}
	return RouteInfo{Class: ClassUnclassified}, true
}
