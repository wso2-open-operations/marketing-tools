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

package features

import (
	"context"
	"log/slog"
	"maps"
	"strings"
	"sync"
	"time"

	"wso2-coin-backend/internal/models"
)

// DefaultTTL is how long a resolved snapshot is served before the next read
// refetches app_config. It is the operator-visible latency of a toggle: flip a
// row and the API stops answering within this window. Short enough that
// "toggle the flag and watch it take effect" is a usable workflow, long
// enough that a per-request DB round trip never lands on the hot path of
// every gated route.
const DefaultTTL = 30 * time.Second

// refreshTimeout bounds one app_config read. The refresh runs on a context
// detached from the triggering request (see refresh), so without its own
// deadline a hung pool would pin the refresh mutex indefinitely.
const refreshTimeout = 5 * time.Second

// Copy used for a feature that has flag rows in the database but no entry in
// this build's registry -- i.e. one added by an operator after this binary
// shipped. Generic on purpose: the microapp is expected to carry the real
// wording, and an operator who wants better copy sets the two override rows.
const (
	genericTitle   = "Coming soon"
	genericMessage = "This feature will be available soon. Please check back later."
)

// enabledKeyPrefix and enabledKeySuffix bracket a feature name in the flag
// key, and are how an unregistered feature is discovered in the row set.
const (
	enabledKeyPrefix = "is_"
	enabledKeySuffix = "_enabled"
)

// ConfigReader is the slice of repository.AppConfigRepo this package needs.
// It is the same List the /app-configs handler uses -- feature flags are
// ordinary rows, so no new query, no new repo method.
type ConfigReader interface {
	List(ctx context.Context) ([]models.AppConfig, error)
}

// State is one feature's resolved configuration: the compiled-in default with
// any app_config override applied on top.
type State struct {
	Feature Feature `json:"feature"`
	Enabled bool    `json:"enabled"`
	Title   string  `json:"comingSoonTitle"`
	Message string  `json:"comingSoonMessage"`
}

// snapshot is one consistent read of app_config: every feature's state plus
// the route mapping that was in force at the same moment. The two travel
// together so a gate decision can never mix a new mapping with an old flag.
type snapshot struct {
	states map[Feature]State
	gates  GateMap
}

// Resolver answers "is this feature on" and "which feature owns this route"
// from app_config, with a TTL cache in front of the table.
//
// Two rules are borrowed from repository.schema.go, for the same reasons given
// there: cache the *answer*, never the failure, and refresh on a context
// detached from whichever request happened to trigger it, so one cancelled
// client does not poison the shared snapshot.
//
// A read never fails. If app_config has never been read successfully the
// compiled-in defaults answer; if it has, the last good snapshot answers until
// a later refresh succeeds. A database outage therefore leaves the app in its
// last known configuration rather than blanking every screen.
type Resolver struct {
	reader ConfigReader
	ttl    time.Duration
	now    func() time.Time

	mu        sync.RWMutex
	current   *snapshot
	fetchedAt time.Time

	// refreshMu serialises refreshes so a burst of requests arriving on a
	// cold or expired cache issues one query rather than one per request.
	refreshMu sync.Mutex
}

// NewResolver builds a Resolver over reader with DefaultTTL. The cache starts
// empty: the first read populates it, and until then every feature answers
// from its compiled-in default and DefaultGateMap governs routing.
func NewResolver(reader ConfigReader) *Resolver {
	return &Resolver{reader: reader, ttl: DefaultTTL, now: time.Now}
}

// defaultSnapshot renders the registry with no overrides applied.
func defaultSnapshot() *snapshot {
	states := make(map[Feature]State, len(definitions))
	for _, d := range definitions {
		states[d.Feature] = State{
			Feature: d.Feature,
			Enabled: d.EnabledByDefault,
			Title:   d.DefaultTitle,
			Message: d.DefaultMessage,
		}
	}
	return &snapshot{states: states, gates: DefaultGateMap()}
}

// featureFromEnabledKey extracts "agenda" from "is_agenda_enabled". It is how
// a feature nobody compiled in still gets a state: the row set is the
// authority on which features exist, not this binary.
func featureFromEnabledKey(key string) (Feature, bool) {
	if !strings.HasPrefix(key, enabledKeyPrefix) || !strings.HasSuffix(key, enabledKeySuffix) {
		return "", false
	}
	name := key[len(enabledKeyPrefix) : len(key)-len(enabledKeySuffix)]
	if name == "" {
		return "", false
	}
	return Feature(name), true
}

// parseEnabled reads the stored spelling of a boolean. "1"/"0" is what the
// rows that predate this package use and what the microapp writes its own
// coercion against; the word forms are accepted because a human editing the
// table by hand reaches for them.
func parseEnabled(v string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true, true
	case "0", "false", "no", "off":
		return false, true
	}
	return false, false
}

// apply overlays the app_config rows onto the compiled-in defaults.
//
// Features are discovered from the rows, not only from the registry, so an
// operator can add is_<something>_enabled plus its two copy rows and have the
// backend and the microapp honour it without either being redeployed. The
// registry supplies defaults and wording for the features this build knows;
// anything else defaults to on with generic copy, because a feature nobody
// declared should not be off by accident.
//
// An unparseable enabled value falls back to the default rather than to false
// -- a typo in one row must not silently take a screen offline. Empty copy
// strings are treated as absent, so blanking a row restores the default
// wording instead of rendering an empty placeholder.
//
// Rows unrelated to features (freshness beacons, partner_domains,
// cache_version) are ignored.
func apply(rows []models.AppConfig) *snapshot {
	byKey := make(map[string]string, len(rows))
	for _, r := range rows {
		byKey[r.Key] = r.Value
	}

	out := defaultSnapshot()

	// Discover features present in the table but absent from this build.
	for key := range byKey {
		f, ok := featureFromEnabledKey(key)
		if !ok {
			continue
		}
		if _, known := out.states[f]; known {
			continue
		}
		out.states[f] = State{
			Feature: f,
			Enabled: true,
			Title:   genericTitle,
			Message: genericMessage,
		}
	}

	for f, s := range out.states {
		if v, ok := byKey[f.EnabledKey()]; ok {
			if enabled, parsed := parseEnabled(v); parsed {
				s.Enabled = enabled
			}
		}
		if v, ok := byKey[f.TitleKey()]; ok && strings.TrimSpace(v) != "" {
			s.Title = v
		}
		if v, ok := byKey[f.MessageKey()]; ok && strings.TrimSpace(v) != "" {
			s.Message = v
		}
		out.states[f] = s
	}

	// The stored mapping replaces the compiled one outright rather than
	// merging with it: a merge would make a route impossible to un-gate
	// from the database, which is the one thing this row exists to allow.
	// A malformed value keeps the compiled map and is logged by the caller.
	if raw, ok := byKey[GateMapKey]; ok {
		if gates, parsed := parseGateMap(raw); parsed {
			out.gates = gates
		}
	}

	return out
}

// load returns the current snapshot, refreshing from app_config first if the
// cached copy has aged past the TTL.
func (r *Resolver) load(ctx context.Context) *snapshot {
	r.mu.RLock()
	cached, fetchedAt := r.current, r.fetchedAt
	r.mu.RUnlock()

	if cached != nil && r.now().Sub(fetchedAt) < r.ttl {
		return cached
	}

	r.refresh(ctx)

	r.mu.RLock()
	cached = r.current
	r.mu.RUnlock()

	if cached == nil {
		return defaultSnapshot()
	}
	return cached
}

// Snapshot returns the resolved state of every feature. The returned map is a
// fresh copy and is safe to hold and mutate.
func (r *Resolver) Snapshot(ctx context.Context) map[Feature]State {
	out := make(map[Feature]State)
	maps.Copy(out, r.load(ctx).states)
	return out
}

// State returns the resolved configuration of one feature. A feature with no
// row and no registry entry reports enabled with generic copy: an unknown name
// is a wiring mistake, and failing open on it keeps a live endpoint live.
func (r *Resolver) State(ctx context.Context, f Feature) State {
	if s, ok := r.load(ctx).states[f]; ok {
		return s
	}
	return State{Feature: f, Enabled: true, Title: genericTitle, Message: genericMessage}
}

// Enabled reports whether f is currently switched on.
func (r *Resolver) Enabled(ctx context.Context, f Feature) bool {
	return r.State(ctx, f).Enabled
}

// Gate reports the feature governing a route, and its state, if the route is
// gated at all. method is the HTTP verb and routePattern is gin's matched
// route (c.FullPath()), not the concrete request path.
func (r *Resolver) Gate(ctx context.Context, method, routePattern string) (State, bool) {
	snap := r.load(ctx)
	f, ok := snap.gates.Feature(method, routePattern)
	if !ok {
		return State{}, false
	}
	if s, known := snap.states[f]; known {
		return s, true
	}
	return State{Feature: f, Enabled: true, Title: genericTitle, Message: genericMessage}, true
}

// refresh reads app_config and replaces the snapshot on success.
//
// The read deliberately does not inherit ctx's cancellation: the snapshot is
// process-wide, so a client that hangs up mid-refresh would otherwise abort a
// fetch every other in-flight request is waiting on. Values (trace ids, the
// logger) are kept; the deadline is this package's own.
func (r *Resolver) refresh(ctx context.Context) {
	r.refreshMu.Lock()
	defer r.refreshMu.Unlock()

	// Another goroutine may have refreshed while this one waited for the
	// mutex. Re-check before spending a query.
	r.mu.RLock()
	fresh := r.current != nil && r.now().Sub(r.fetchedAt) < r.ttl
	r.mu.RUnlock()
	if fresh {
		return
	}

	fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), refreshTimeout)
	defer cancel()

	rows, err := r.reader.List(fetchCtx)
	if err != nil {
		// Keep serving the previous answer (or the defaults). Not caching
		// the failure means the next request retries rather than waiting
		// out a TTL on a value nobody verified.
		slog.WarnContext(ctx, "reading feature flags from app_config failed; serving last known configuration", "error", err)
		return
	}

	next := apply(rows)

	// Warn loudly on a malformed mapping: the API keeps gating exactly what
	// this build was tested against, so nothing breaks, but the operator's
	// edit silently did nothing and they need to know.
	for _, row := range rows {
		if row.Key != GateMapKey {
			continue
		}
		if _, ok := parseGateMap(row.Value); !ok {
			slog.ErrorContext(ctx, "app_config."+GateMapKey+" is not valid JSON; keeping the built-in route mapping")
		}
		break
	}

	r.mu.Lock()
	r.current = next
	r.fetchedAt = r.now()
	r.mu.Unlock()
}
