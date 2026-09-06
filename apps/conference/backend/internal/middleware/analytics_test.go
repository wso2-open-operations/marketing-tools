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

package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/analytics"
)

// recordingRecorder captures what the middleware produced. It locks because
// analytics.Recorder promises concurrency safety and the concurrency test below
// takes that promise literally.
type recordingRecorder struct {
	mu     sync.Mutex
	events []analytics.Event
}

func (r *recordingRecorder) Record(e analytics.Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, e)
}

func (r *recordingRecorder) Close(context.Context) error { return nil }

func (r *recordingRecorder) all() []analytics.Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]analytics.Event(nil), r.events...)
}

// one asserts exactly one event was recorded and returns it.
func (r *recordingRecorder) one(t *testing.T) analytics.Event {
	t.Helper()
	events := r.all()
	if len(events) != 1 {
		t.Fatalf("recorded %d events, want 1", len(events))
	}
	return events[0]
}

// analyticsRouter builds an engine wired the way main.go wires it: analytics at
// engine level, outside both Recovery and the auth-gated group.
func analyticsRouter(rec analytics.Recorder, policy analytics.RoutePolicy) *gin.Engine {
	gin.SetMode(gin.TestMode)

	r := gin.New()
	r.Use(Analytics(rec, policy))
	r.Use(gin.Recovery())

	return r
}

// testPolicy classifies /tracked and skips /skipped, so these tests do not
// depend on the production table's contents -- routes_test.go owns that.
func testPolicy() analytics.RoutePolicy {
	return analytics.NewRoutePolicy(
		map[string]struct{}{"GET /skipped": {}},
		map[string]analytics.RouteInfo{
			"GET /tracked":      {Feature: "agenda", Class: analytics.ClassIntent},
			"GET /tracked/:id":  {Feature: "agenda", Class: analytics.ClassIntent},
			"POST /tracked":     {Feature: "agenda", Class: analytics.ClassIntent},
			"GET /boom":         {Feature: "agenda", Class: analytics.ClassIntent},
			"GET /user-profile": {Feature: "attendees", Class: analytics.ClassScreen},
		},
	)
}

func TestAnalytics_RecordsRouteTemplateNotSubstitutedPath(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/tracked/:id", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/tracked/9f8e7d6c", nil)
	r.ServeHTTP(httptest.NewRecorder(), req)

	got := rec.one(t)
	// Route is what a dashboard groups by. Had it been the substituted path,
	// one endpoint would scatter across as many series as there are ids.
	if got.Route != "/tracked/:id" {
		t.Errorf("Route = %q, want /tracked/:id", got.Route)
	}
	if got.URI != "/tracked/9f8e7d6c" {
		t.Errorf("URI = %q, want the real path", got.URI)
	}
	if got.Feature != "agenda" || got.Class != string(analytics.ClassIntent) {
		t.Errorf("Feature/Class = %q/%q, want agenda/intent", got.Feature, got.Class)
	}
}

func TestAnalytics_SkippedRouteRecordsNothing(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/skipped", func(c *gin.Context) { c.Status(http.StatusOK) })

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/skipped", nil))

	if events := rec.all(); len(events) != 0 {
		t.Errorf("recorded %d events for a skipped route, want 0", len(events))
	}
}

func TestAnalytics_UnmatchedRouteRecordsNothing(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/wp-login.php", nil))

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", w.Code)
	}
	if events := rec.all(); len(events) != 0 {
		t.Errorf("recorded %d events for scanner noise, want 0", len(events))
	}
}

func TestAnalytics_RecordsRealStatusAndUser(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())

	// Stand in for Auth: publish identity the way Auth does, by replacing
	// c.Request with one whose context carries the UserInfo. The middleware
	// under test runs *before* this, so this also proves it reads identity back
	// after c.Next().
	r.Use(func(c *gin.Context) {
		c.Request = c.Request.WithContext(WithUserInfo(c.Request.Context(), &UserInfo{
			Email:  "attendee@example.com",
			UserID: "user-uuid-123",
		}))
		c.Next()
	})
	r.GET("/tracked", func(c *gin.Context) { c.JSON(http.StatusTeapot, gin.H{"message": "no"}) })

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/tracked", nil))

	got := rec.one(t)
	if got.Status != http.StatusTeapot {
		t.Errorf("Status = %d, want %d", got.Status, http.StatusTeapot)
	}
	// The UUID, never the email address.
	if got.UserID != "user-uuid-123" {
		t.Errorf("UserID = %q, want user-uuid-123", got.UserID)
	}
	if got.ResponseBytes <= 0 {
		t.Errorf("ResponseBytes = %d, want the written body size", got.ResponseBytes)
	}
	if got.End.Before(got.Start) {
		t.Error("End must not precede Start")
	}
}

func TestAnalytics_AbortedRequestIsRecordedAnonymously(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())

	// A stand-in for Auth rejecting a request: it aborts, so nothing after it
	// runs. Analytics is registered before it, which is why the 401 is still
	// visible instead of vanishing from the dashboard.
	r.Use(func(c *gin.Context) {
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing authorization token"})
	})
	r.GET("/tracked", func(c *gin.Context) { c.Status(http.StatusOK) })

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/tracked", nil))

	got := rec.one(t)
	if got.Status != http.StatusUnauthorized {
		t.Errorf("Status = %d, want 401", got.Status)
	}
	if got.UserID != "" {
		t.Errorf("UserID = %q, want empty for a rejected request", got.UserID)
	}
}

func TestAnalytics_PanickingHandlerIsRecordedAs500(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/boom", func(c *gin.Context) { panic("boom") })

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/boom", nil))

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", w.Code)
	}
	// Sitting outside Recovery is what makes this work; inside it, the event
	// would be lost exactly when it matters most.
	if got := rec.one(t); got.Status != http.StatusInternalServerError {
		t.Errorf("Status = %d, want 500", got.Status)
	}
}

func TestAnalytics_RedactsSensitiveQueryValuesButKeepsKeys(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/user-profile", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/user-profile?email=attendee@example.com&eventId=abc123", nil)
	r.ServeHTTP(httptest.NewRecorder(), req)

	got := rec.one(t)
	if strings.Contains(got.URI, "attendee@example.com") {
		t.Errorf("URI = %q, must not carry the email address", got.URI)
	}
	// The key survives, so "somebody looked up a profile by email" is still
	// answerable.
	if !strings.Contains(got.URI, "email=") {
		t.Errorf("URI = %q, want the email key retained", got.URI)
	}
	if !strings.Contains(got.URI, "eventId=abc123") {
		t.Errorf("URI = %q, want the allow-listed eventId value retained", got.URI)
	}
}

func TestAnalytics_RedactsSearchTerms(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/tracked", func(c *gin.Context) { c.Status(http.StatusOK) })

	// A speaker search term is free text an attendee typed; in practice it is a
	// colleague's name.
	req := httptest.NewRequest(http.MethodGet, "/tracked?q=Jane+Doe&previous=true", nil)
	r.ServeHTTP(httptest.NewRecorder(), req)

	got := rec.one(t)
	if strings.Contains(got.URI, "Jane") {
		t.Errorf("URI = %q, must not carry the search term", got.URI)
	}
	if !strings.Contains(got.URI, "previous=true") {
		t.Errorf("URI = %q, want the allow-listed previous value retained", got.URI)
	}
}

func TestAnalytics_DoesNotForwardCredentialHeaders(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/tracked", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/tracked", nil)
	req.Header.Set(jwtAssertionHeader, "a.signed.jwt")
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Cookie", "session=secret")
	req.Header.Set("User-Agent", "conference-microapp/1.0")
	req.Header.Set("Accept-Language", "en-GB")
	r.ServeHTTP(httptest.NewRecorder(), req)

	got := rec.one(t)
	for _, banned := range []string{jwtAssertionHeader, "Authorization", "Cookie"} {
		for name, value := range got.RequestHeaders {
			if strings.EqualFold(name, banned) {
				t.Errorf("request header %q was forwarded with value %q", name, value)
			}
		}
	}
	if got.RequestHeaders["User-Agent"] != "conference-microapp/1.0" {
		t.Errorf("User-Agent = %q, want it retained for the device breakdown", got.RequestHeaders["User-Agent"])
	}
	if got.RequestHeaders["Accept-Language"] != "en-GB" {
		t.Errorf("Accept-Language = %q, want it retained", got.RequestHeaders["Accept-Language"])
	}
}

func TestAnalytics_RecordsRequestBodySizeWithoutTheBody(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.POST("/tracked", func(c *gin.Context) { c.Status(http.StatusCreated) })

	body := `{"question":"who should I talk to about ballerina"}`
	req := httptest.NewRequest(http.MethodPost, "/tracked", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	r.ServeHTTP(httptest.NewRecorder(), req)

	got := rec.one(t)
	if got.RequestBytes != int64(len(body)) {
		t.Errorf("RequestBytes = %d, want %d", got.RequestBytes, len(body))
	}
	if got.RequestHeaders["Content-Type"] != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got.RequestHeaders["Content-Type"])
	}
}

func TestAnalytics_UnknownLengthsBecomeZeroNotNegative(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	// A handler that writes nothing leaves gin's writer reporting size -1.
	r.GET("/tracked", func(c *gin.Context) {})

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/tracked", nil))

	got := rec.one(t)
	if got.RequestBytes < 0 || got.ResponseBytes < 0 {
		t.Errorf("lengths = %d/%d, want no negatives", got.RequestBytes, got.ResponseBytes)
	}
}

func TestAnalytics_HeaderMapsAreNotSharedBetweenEvents(t *testing.T) {
	rec := &recordingRecorder{}
	r := analyticsRouter(rec, testPolicy())
	r.GET("/tracked", func(c *gin.Context) { c.Status(http.StatusOK) })

	for _, ua := range []string{"agent-one", "agent-two"} {
		req := httptest.NewRequest(http.MethodGet, "/tracked", nil)
		req.Header.Set("User-Agent", ua)
		r.ServeHTTP(httptest.NewRecorder(), req)
	}

	events := rec.all()
	if len(events) != 2 {
		t.Fatalf("recorded %d events, want 2", len(events))
	}
	// The recorder marshals asynchronously, so a shared map would let a later
	// request rewrite an earlier event's headers mid-flight.
	if events[0].RequestHeaders["User-Agent"] == events[1].RequestHeaders["User-Agent"] {
		t.Error("both events share one header map")
	}
}

func TestAnalytics_NopRecorderIsUsable(t *testing.T) {
	r := analyticsRouter(analytics.Nop{}, analytics.DefaultRoutePolicy())
	r.GET("/events", func(c *gin.Context) { c.Status(http.StatusOK) })

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/events", nil))

	// The point is that analytics being switched off changes nothing about the
	// response the attendee gets.
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}
