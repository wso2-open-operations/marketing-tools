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

package repository

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// schemaCaps caches whether optional columns of the *shared* marketingops
// schema are present.
//
// This backend does not own that schema -- the agenda-organizer repo does, and
// its migrations are applied by hand with no migration-state table (see
// .claude/PLAN.endpoint-gap.md §5.4). So at any moment the live database may
// sit at any upstream revision, and a query naming a column that a not-yet-
// applied migration adds -- or one that an already-applied migration dropped --
// fails outright rather than degrading.
//
// The concrete case this exists for: upstream 023 added sessions.topic_id and
// the track_topics table, and 024 then *dropped* sessions.category. A query
// hardcoded either way 500s against half the possible database states. Probing
// once and shaping the SELECT accordingly means the agenda endpoints work
// against every upstream revision from 018 through 025.
//
// The second capability is the same story one migration later: upstream 027
// adds rooms.color_token/tracks.color_token, which every session, speaker and
// agenda read now selects. Naming them against a database that predates 027
// would 500 those reads outright, so an unprobed or absent column degrades to
// the literal ColorTokenDefault -- the same value the COALESCE would have
// produced for a row with no token anywhere.
//
// The third runs the same way in the other direction, against an *older*
// migration: upstream 018 added conference_config.venue_name/venue_address, and
// GET /activities now sources an activity's location from them. 018 predates
// everything else probed here, so a database carrying it is the ordinary case --
// but "ordinary" is not "guaranteed" when migrations are applied by hand, and a
// database below 018 would 500 the whole endpoint rather than lose one nested
// object. Absent, the columns degrade to NULL, which is the same shape the
// (nullable, unpopulated by default) columns produce anyway and which
// ActivityRepo.List already has to render as no location at all.
//
// The fourth is the first one about whole *tables* rather than columns: upstream
// 029 adds con_activities and con_activity_hours, and GET /activities now reads
// them instead of sessions.kind='activity'. A missing table is the harsher
// failure of the two -- a query naming it cannot even be planned, so the
// endpoint 500s outright where a missing column at least fails inside a query
// that made sense. Absent, the whole read is skipped and the endpoint returns an
// empty list, which is the same degrade-to-empty the rest of this package does
// and what lets this ship before the migration is applied by hand.
//
// A failed probe degrades *that request only* to the safe form and stays
// unresolved, so the next request retries. Memoizing a failure would turn a
// one-off blip into a permanent, silent loss of the field for the lifetime of
// the process -- the capability is cached once it is actually known, not once it
// has been asked about.
//
// Only an answered probe is cached, so a migration applied by hand while the
// server is running is still not picked up until something re-probes; once the
// capability resolves true it never needs to change, and the reverse (an
// upstream rollback) is not a state this degrades into silently, because the
// query would then fail loudly rather than return wrong data.
type schemaCaps struct {
	mu        sync.Mutex
	resolved  bool
	hasTopics bool

	// Colour-token capability, resolved independently of the topic one: the
	// two arrive in different upstream migrations, so a database can have
	// either, both or neither.
	colorResolved      bool
	hasRoomColorToken  bool
	hasTrackColorToken bool

	// Venue capability, resolved independently for the same reason: upstream
	// 018 is a different migration again, so its columns are a third fact that
	// can be present while the others are not, and the other way round.
	venueResolved   bool
	hasVenueName    bool
	hasVenueAddress bool

	// Activity-table capability, resolved independently again: upstream 029 is
	// a fourth migration, and unlike the three above it is about tables rather
	// than columns. Both tables sit under one flag because 029 creates them in
	// one transaction and neither is usable without the other -- con_activities
	// alone has no opening hours to publish, con_activity_hours alone has no
	// name to publish.
	activityTablesResolved bool
	hasActivityTables      bool
}

// schemaProbeTimeout bounds a single capability probe -- one EXISTS against
// information_schema, and one only. Two probes under one budget is the bug this
// constant used to have; see probeContext.
//
// It has to cover a *cold pool connect*, which is what makes 3s -- the value it
// carried while the budget was shared -- too small rather than merely tight.
// pgxpool.New does not dial; the first request after a restart opens the
// connection, and it opens it inside whatever probe runs first. Against the
// staging Azure instance that dial measures ~2.6s (TLS plus auth, cross-region),
// leaving a shared 3s budget ~200ms for two round-trips: measured over five cold
// starts, activityTables blew the deadline on one of them and GET /activities
// answered 200 with an empty array. The warm cost being ~250ms is not the case
// to size for, because the cold one is the only case that ever runs -- a
// capability resolves once per process.
//
// Ten seconds is therefore about a cold dial with room for a slow one, not about
// the query. A request does wait that long in the worst case, but at most one
// request per capability per process does, and for the table capability the
// alternative is not a slower answer -- it is a wrong one. An unanswered probe
// there degrades to an *empty endpoint* rather than a missing field (see
// activityTables), and the ETag middleware stamps that empty array
// `private, max-age=60`, so one lost race becomes a minute of a client showing
// no amenities at all.
const schemaProbeTimeout = 10 * time.Second

// probeContext returns the context for exactly one probe query.
//
// One per query, never one per capability. The venue, colour and activity
// capabilities each run two probes in sequence, and sharing a single deadline
// across both means the second one inherits whatever the first left -- which,
// when the first also paid the pool's cold dial, is nothing. Each probe getting
// its own budget is what makes schemaProbeTimeout mean what it says.
//
// The detachment lives here too, in one place, because it is the same reason at
// every call site: a request-scoped context is the wrong lifetime for a
// process-wide fact. Without it the first request to arrive decides the
// capability for every later one, and a client that disconnects mid-probe
// cancels it -- indistinguishable, at this layer, from the column or table
// genuinely being absent.
func probeContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), schemaProbeTimeout)
}

// probeColumn answers columnExists for one column under its own deadline.
func probeColumn(ctx context.Context, pool *pgxpool.Pool, table, column string) (bool, error) {
	probeCtx, cancel := probeContext(ctx)
	defer cancel()
	return columnExists(probeCtx, pool, table, column)
}

// probeTable answers tableExists for one table under its own deadline.
func probeTable(ctx context.Context, pool *pgxpool.Pool, table string) (bool, error) {
	probeCtx, cancel := probeContext(ctx)
	defer cancel()
	return tableExists(probeCtx, pool, table)
}

// columnExists reports whether table.column exists in the connection's current
// schema (set from DB_SCHEMA via the DSN's search_path). A probe that could not
// be answered is an error, distinct from an answered "no" -- the caller has to
// tell them apart to know whether the result is worth caching.
func columnExists(ctx context.Context, pool *pgxpool.Pool, table, column string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx,
		`SELECT EXISTS (
		   SELECT 1 FROM information_schema.columns
		   WHERE table_schema = current_schema()
		     AND table_name = $1
		     AND column_name = $2
		 )`,
		table, column,
	).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists, nil
}

// tableExists reports whether a table exists in the connection's current schema
// (set from DB_SCHEMA via the DSN's search_path). The table-level twin of
// columnExists, and it answers a different question than "does this column
// exist": a query naming a missing column and a query naming a missing table
// both fail, but only the second one is unanswerable even in principle, so a
// caller cannot substitute an expression for it the way venueSQL substitutes
// NULL::text -- it has to skip the read entirely.
//
// information_schema.tables is filtered to BASE TABLE and VIEW by default for
// objects the current user can see, which is what we want: a table that exists
// but is unreadable is, for this purpose, a table that is not there. As with
// columnExists, a probe that could not be answered is an error distinct from an
// answered "no", because only the latter is worth caching.
func tableExists(ctx context.Context, pool *pgxpool.Pool, table string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx,
		`SELECT EXISTS (
		   SELECT 1 FROM information_schema.tables
		   WHERE table_schema = current_schema()
		     AND table_name = $1
		 )`,
		table,
	).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists, nil
}

// topicSQL returns the SELECT expression and the extra JOIN clause to use for a
// session's topic label -- the field the API still exposes as `category`.
//
// When upstream 023 has been applied, the label comes from the resolved topic
// (track_topics.name, e.g. "API Management"). Otherwise it degrades to a
// literal NULL, which scans into a nil *string and serializes as an omitted
// key -- exactly what sessions.category produced before 024 dropped it, since
// that column was NULL on every row.
func (c *schemaCaps) topicSQL(ctx context.Context, pool *pgxpool.Pool) (selectExpr, joinClause string) {
	if c.hasTopicID(ctx, pool) {
		return "tt.name", "LEFT JOIN track_topics tt ON tt.id = s.topic_id"
	}
	return "NULL::text", ""
}

// hasTopicID reports whether sessions.topic_id exists, probing at most once
// successfully and retrying on every request until it gets an answer.
//
// The probe runs detached from the caller's context and under its own deadline;
// probeContext owns both decisions and the reasons for them.
//
// The lock is not held across the query. Concurrent callers on a cold cache may
// each probe, which costs a duplicate EXISTS against information_schema and
// nothing else; holding it would instead serialise every request behind one
// round-trip, which is the worse trade when the database is slow.
func (c *schemaCaps) hasTopicID(ctx context.Context, pool *pgxpool.Pool) bool {
	c.mu.Lock()
	if c.resolved {
		defer c.mu.Unlock()
		return c.hasTopics
	}
	c.mu.Unlock()

	exists, err := probeColumn(ctx, pool, "sessions", "topic_id")
	if err != nil {
		// Serve this request in the degraded shape but leave the capability
		// unresolved, so a transient failure costs one request's category
		// field rather than every request until the process restarts.
		slog.Warn("schema capability probe failed, serving degraded",
			"table", "sessions", "column", "topic_id", "error", err)
		return false
	}

	c.mu.Lock()
	c.resolved, c.hasTopics = true, exists
	c.mu.Unlock()

	slog.Info("schema capability resolved", "table", "sessions", "column", "topic_id", "present", exists)
	return exists
}

// colorTokenSQL returns the SELECT expression for a session's colour token --
// the only colour field the API publishes.
//
// Upstream 027 puts the token on rooms and tracks and fixes the precedence:
// COALESCE(rooms.color_token, tracks.color_token, 'main'). The colour belongs
// to the room, the stable thing an attendee navigates by; the track is the
// fallback for tracks that have no room. The expression assumes the caller's
// query already aliases rooms as r and tracks as t, which all four colour-
// reading queries do.
//
// Each column is folded in only if it is actually there, so a database at any
// point of the 027 rollout -- neither column, or one of them if the ALTERs are
// applied separately -- gets a valid query rather than a 500. With neither, the
// expression is the literal default: every session comes back "main", which is
// exactly what a client renders for a row that has no token upstream either.
func (c *schemaCaps) colorTokenSQL(ctx context.Context, pool *pgxpool.Pool) string {
	return colorTokenExpr(c.colorTokenColumns(ctx, pool))
}

// colorTokenExpr builds the expression for a given pair of capabilities. Split
// out from the probe so the precedence it encodes -- room, then track, then the
// default -- is testable without a database.
func colorTokenExpr(room, track bool) string {
	switch {
	case room && track:
		return fmt.Sprintf("COALESCE(r.color_token, t.color_token, '%s')", ColorTokenDefault)
	case room:
		return fmt.Sprintf("COALESCE(r.color_token, '%s')", ColorTokenDefault)
	case track:
		return fmt.Sprintf("COALESCE(t.color_token, '%s')", ColorTokenDefault)
	default:
		return fmt.Sprintf("'%s'::text", ColorTokenDefault)
	}
}

// colorTokenColumns reports whether rooms.color_token and tracks.color_token
// exist, probing at most once successfully and retrying on every request until
// it gets an answer.
//
// Same lifetime rules as hasTopicID, for the same reasons: the probe runs
// detached from the caller's context so one request cannot decide a
// process-wide fact by disconnecting mid-probe, the lock is not held across the
// query, and only an answered probe is cached so a transient failure costs one
// request's colour rather than every request until the process restarts.
//
// Both columns are probed under one resolved flag because 027 adds them
// together; two round trips on a cold cache is the price of not inventing a
// second caching scheme for a fact that always moves as a pair.
func (c *schemaCaps) colorTokenColumns(ctx context.Context, pool *pgxpool.Pool) (room, track bool) {
	c.mu.Lock()
	if c.colorResolved {
		defer c.mu.Unlock()
		return c.hasRoomColorToken, c.hasTrackColorToken
	}
	c.mu.Unlock()

	room, err := probeColumn(ctx, pool, "rooms", "color_token")
	if err == nil {
		track, err = probeColumn(ctx, pool, "tracks", "color_token")
	}
	if err != nil {
		// Serve this request with the default token and leave the capability
		// unresolved, so the next request re-probes.
		slog.Warn("schema capability probe failed, serving degraded",
			"table", "rooms/tracks", "column", "color_token", "error", err)
		return false, false
	}

	c.mu.Lock()
	c.colorResolved, c.hasRoomColorToken, c.hasTrackColorToken = true, room, track
	c.mu.Unlock()

	slog.Info("schema capability resolved", "table", "rooms/tracks", "column", "color_token",
		"rooms", room, "tracks", track)
	return room, track
}

// venueSQL returns the SELECT expressions for the conference's venue name and
// address -- the source of an activity's location.
//
// Upstream 018 puts both on conference_config, and the expressions assume the
// caller's query already aliases that table as cc, which the one venue-reading
// query does. Each column is folded in only if it is actually there, so a
// database below 018 -- or one mid-018, if the ALTERs were split -- gets a valid
// query instead of a 500 on the whole endpoint.
//
// The degraded form is NULL::text rather than an empty literal so it scans into
// the same *string the resolved form does, and so an absent column is
// indistinguishable downstream from the far more common case of a column that is
// there and unpopulated: both mean "no location recorded", and both must produce
// no location object at all rather than one with an empty name.
func (c *schemaCaps) venueSQL(ctx context.Context, pool *pgxpool.Pool) (nameExpr, addressExpr string) {
	return venueExprs(c.venueColumns(ctx, pool))
}

// venueExprs builds the two expressions for a given pair of capabilities. Split
// out from the probe, like colorTokenExpr, so the degraded shape is testable
// without a database.
func venueExprs(name, address bool) (nameExpr, addressExpr string) {
	nameExpr, addressExpr = "NULL::text", "NULL::text"
	if name {
		nameExpr = "cc.venue_name"
	}
	if address {
		addressExpr = "cc.venue_address"
	}
	return nameExpr, addressExpr
}

// venueColumns reports whether conference_config.venue_name and
// conference_config.venue_address exist, probing at most once successfully and
// retrying on every request until it gets an answer.
//
// Same lifetime rules as hasTopicID and colorTokenColumns, for the same reasons:
// the probe runs detached from the caller's context so one request cannot decide
// a process-wide fact by disconnecting mid-probe, the lock is not held across the
// query, and only an answered probe is cached so a transient failure costs one
// request's location rather than every request until the process restarts.
//
// Both columns sit under one resolved flag because 018 adds them in a single
// ALTER, the same trade colorTokenColumns makes for 027.
func (c *schemaCaps) venueColumns(ctx context.Context, pool *pgxpool.Pool) (name, address bool) {
	c.mu.Lock()
	if c.venueResolved {
		defer c.mu.Unlock()
		return c.hasVenueName, c.hasVenueAddress
	}
	c.mu.Unlock()

	name, err := probeColumn(ctx, pool, "conference_config", "venue_name")
	if err == nil {
		address, err = probeColumn(ctx, pool, "conference_config", "venue_address")
	}
	if err != nil {
		// Serve this request without a location and leave the capability
		// unresolved, so the next request re-probes.
		slog.Warn("schema capability probe failed, serving degraded",
			"table", "conference_config", "column", "venue_name/venue_address", "error", err)
		return false, false
	}

	c.mu.Lock()
	c.venueResolved, c.hasVenueName, c.hasVenueAddress = true, name, address
	c.mu.Unlock()

	slog.Info("schema capability resolved", "table", "conference_config",
		"column", "venue_name/venue_address", "name", name, "address", address)
	return name, address
}

// activityTables reports whether upstream 029's con_activities and
// con_activity_hours are both present, probing at most once successfully and
// retrying on every request until it gets an answer.
//
// Same lifetime rules as hasTopicID, colorTokenColumns and venueColumns, for the
// same reasons: the probe runs detached from the caller's context so one request
// cannot decide a process-wide fact by disconnecting mid-probe, the lock is not
// held across the query, and only an answered probe is cached so a transient
// failure costs one request's activities rather than every request until the
// process restarts.
//
// The two tables are ANDed rather than reported separately. Unlike the venue
// columns -- where a half-applied migration still leaves something worth
// publishing -- half of 029 publishes nothing: without con_activity_hours there
// are no times, and an activity with no time is exactly the card this endpoint
// has always refused to render. So the capability is "can this endpoint be
// served at all", and the second probe is skipped when the first already
// answered no.
//
// Absent, GET /activities returns an empty list rather than an error. That is a
// real behaviour difference from the column capabilities, which only ever cost a
// field: here the endpoint is genuinely empty until 029 is applied by hand, and
// empty is the honest answer -- the venue has no amenities recorded, because
// there is nowhere yet to record them.
func (c *schemaCaps) activityTables(ctx context.Context, pool *pgxpool.Pool) bool {
	c.mu.Lock()
	if c.activityTablesResolved {
		defer c.mu.Unlock()
		return c.hasActivityTables
	}
	c.mu.Unlock()

	exists, err := probeTable(ctx, pool, "con_activities")
	if err == nil && exists {
		exists, err = probeTable(ctx, pool, "con_activity_hours")
	}
	if err != nil {
		// Serve this request with no activities and leave the capability
		// unresolved, so the next request re-probes rather than inheriting a
		// blip as a permanently empty endpoint.
		slog.Warn("schema capability probe failed, serving degraded",
			"table", "con_activities/con_activity_hours", "error", err)
		return false
	}

	c.mu.Lock()
	c.activityTablesResolved, c.hasActivityTables = true, exists
	c.mu.Unlock()

	slog.Info("schema capability resolved",
		"table", "con_activities/con_activity_hours", "present", exists)
	return exists
}
