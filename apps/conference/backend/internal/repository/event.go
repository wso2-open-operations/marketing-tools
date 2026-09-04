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
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// EventRepo provides read access to the conference_config/conference_days
// tables (the old Ballerina "event"/"agenda" concepts -- see .claude/PLAN.md).
type EventRepo struct {
	pool        *pgxpool.Pool
	slotMinutes int
	piiKey      []byte
	loc         *time.Location
	venueTZ     string
	caps        schemaCaps
}

// NewEventRepo constructs an EventRepo backed by the given pool. slotMinutes
// is used the same way as SessionRepo's, to compute each nested session's
// StartTime/EndTime. loc anchors those times to the venue timezone and
// venueTZ is its IANA name, surfaced in the payload as Timezone so the client
// stops hardcoding its own. A nil loc defaults to UTC.
//
// piiKey decrypts the speaker columns embedded on each agenda session
// (speakers.name/title/company are encrypted at rest -- see internal/crypto).
// It is the same key SessionRepo takes, for the same join.
func NewEventRepo(pool *pgxpool.Pool, slotMinutes int, piiKey []byte, loc *time.Location, venueTZ string) *EventRepo {
	if loc == nil {
		loc = time.UTC
	}
	if venueTZ == "" {
		venueTZ = loc.String()
	}
	return &EventRepo{pool: pool, slotMinutes: slotMinutes, piiKey: piiKey, loc: loc, venueTZ: venueTZ}
}

// eventDateCols selects the two date bounds every Event carries. start_date is
// a real column; there is no end_date one, so the end of the conference is the
// last day the content team entered for it.
//
// The COALESCE is what keeps EndDate non-empty for a conference whose days are
// not entered yet: MAX over no rows is NULL, and start_date stands in. Postgres
// GREATEST happens to skip NULLs too, but spelling the fallback out does not
// depend on that -- a reader expecting SQL's usual NULL propagation reads this
// correctly either way. GREATEST then clamps the case where the days were
// entered before a wrong start_date was corrected, so EndDate >= StartDate
// always holds.
const eventDateCols = `cc.start_date,
	        GREATEST(cc.start_date, COALESCE(
	            (SELECT MAX(d.date) FROM conference_days d WHERE d.config_id = cc.id),
	            cc.start_date))`

// formatEventDates fills in the two date bounds, matching the YYYY-MM-DD shape
// EventAgenda.Date already uses. Both columns are DATE, so there is no
// timezone conversion to do here -- they are venue-local calendar dates by
// construction.
func formatEventDates(e *models.Event, startDate, endDate time.Time) {
	e.StartDate = startDate.Format("2006-01-02")
	e.EndDate = endDate.Format("2006-01-02")
}

// GetEvents returns every conference_config row, ordered by start_date
// descending. IsCurrent is true only for the first (latest) row -- there is
// no stored "current" flag, so this reuses the "current = latest start_date"
// rule already established for GET /sessions/current.
//
// The id tiebreaker is what makes that rule shared rather than merely stated.
// Three separate statements resolve "current" -- here, GetCurrentEvent, and the
// literal "current" in GetEventAgendas -- and on a bare start_date sort two rows
// with the same date leave the winner to the planner, independently per query.
// GET /events could then flag one event isCurrent while GET /events/current
// returned another.
func (r *EventRepo) GetEvents(ctx context.Context) ([]models.Event, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT cc.id, cc.name, cc.timezone, cc.venue_name, cc.venue_address, `+eventDateCols+`
		 FROM conference_config cc
		 ORDER BY cc.start_date DESC, cc.id DESC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	events := make([]models.Event, 0)
	for rows.Next() {
		var e models.Event
		var tz string
		var venueName, venueAddress *string
		var startDate, endDate time.Time
		if err := rows.Scan(&e.ID, &e.Name, &tz, &venueName, &venueAddress, &startDate, &endDate); err != nil {
			return nil, err
		}
		formatEventDates(&e, startDate, endDate)
		e.IsCurrent = len(events) == 0
		// The conference_config.timezone column is the source of truth; the
		// env-configured venueTZ is only a fallback for an empty value.
		e.Timezone = tz
		if e.Timezone == "" {
			e.Timezone = r.venueTZ
		}
		if venueName != nil {
			e.VenueName = *venueName
		}
		if venueAddress != nil {
			e.VenueAddress = *venueAddress
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

// GetCurrentEvent returns the single "current" conference -- the
// conference_config with the latest start_date, breaking a tie on id, the same
// rule every other "current conference" resolution here uses (GetEvents,
// GetEventAgendas, and the config_id subqueries in session.go, activity.go and
// speaker.go). IsCurrent is therefore always true on the returned row.
//
// The tiebreaker is load-bearing, not cosmetic: these are six independent
// statements, and on a bare start_date sort each one picks its own winner among
// tied rows. GET /events/current could then name one conference while
// GET /sessions/current listed another's sessions.
//
// Returns ErrNotFound when no conference_config row exists at all, which the
// handler maps to 404: the client (useCurrentEvent) reads `event.id` to pin
// every later request to an event, so an empty object would be worse than an
// explicit miss.
func (r *EventRepo) GetCurrentEvent(ctx context.Context) (models.Event, error) {
	var e models.Event
	var tz string
	var venueName, venueAddress *string
	var startDate, endDate time.Time

	err := r.pool.QueryRow(ctx,
		`SELECT cc.id, cc.name, cc.timezone, cc.venue_name, cc.venue_address, `+eventDateCols+`
		 FROM conference_config cc
		 ORDER BY cc.start_date DESC, cc.id DESC
		 LIMIT 1`,
	).Scan(&e.ID, &e.Name, &tz, &venueName, &venueAddress, &startDate, &endDate)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return models.Event{}, ErrNotFound
		}
		return models.Event{}, err
	}

	e.IsCurrent = true
	formatEventDates(&e, startDate, endDate)
	// conference_config.timezone is the source of truth; the env-configured
	// venueTZ is only a fallback for an empty value.
	e.Timezone = tz
	if e.Timezone == "" {
		e.Timezone = r.venueTZ
	}
	if venueName != nil {
		e.VenueName = *venueName
	}
	if venueAddress != nil {
		e.VenueAddress = *venueAddress
	}
	return e, nil
}

// GetEventAgendas returns every conference_days row for the given eventID,
// ordered by day_index, each with its scheduled sessions grouped in (ordered
// by slot_index). A day with zero sessions still appears, with an empty (not
// omitted) Sessions slice. An eventID with no matching conference_config
// returns an empty slice, not an error -- matches the old Ballerina
// per-day-loop behavior, where no rows was never an error case.
//
// The nested sessions carry their speakers, the same shape GET /sessions/:id
// and GET /sessions/current embed (fetchSessionSpeakers, one extra query for
// the whole agenda -- not one per session). They used to be omitted to keep
// the day payload small, but the AI picked-for-you service reads its
// sessionSpeakers off this response and got nothing, and a client that has to
// re-fetch each session to name its speakers is the client-side join this API
// exists to remove.
//
// eventID may be the literal string "current", which resolves to the
// conference_config with the latest start_date (same rule as GetEvents).
func (r *EventRepo) GetEventAgendas(ctx context.Context, eventID string) ([]models.EventAgenda, error) {
	configID := eventID
	if eventID == "current" {
		err := r.pool.QueryRow(ctx,
			"SELECT id FROM conference_config ORDER BY start_date DESC, id DESC LIMIT 1",
		).Scan(&configID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return []models.EventAgenda{}, nil
			}
			return nil, err
		}
	}

	topicExpr, topicJoin := r.caps.topicSQL(ctx, r.pool)

	rows, err := r.pool.Query(ctx,
		fmt.Sprintf(
			`SELECT d.id, d.date, d.label, d.start_minute, cc.timezone,
			        s.id, s.kind, s.title, s.description, %s,
			        s.track_id, s.room_id, s.slot_index, s.duration_slots,
			        s.article_url, s.article_label, s.video_url, s.video_label,
			        r.name, %s, sec.label
			 FROM conference_days d
			 JOIN conference_config cc ON cc.id = d.config_id
			 LEFT JOIN sessions s ON s.day_id = d.id
			 LEFT JOIN tracks t ON t.id = s.track_id
			 LEFT JOIN rooms r ON r.id = s.room_id
			 LEFT JOIN track_sections sec ON sec.id = s.section_id
			 %s
			 WHERE d.config_id = $1
			 ORDER BY d.day_index, s.slot_index NULLS LAST, s.id`,
			topicExpr, r.caps.colorTokenSQL(ctx, r.pool), topicJoin,
		),
		configID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	byDay := make(map[string]*models.EventAgenda)

	for rows.Next() {
		var dayID string
		var date time.Time
		var label *string
		var startMinute int
		var cfgTZ string
		var sessionID, kind, title, description *string
		var category, trackID, roomID *string
		var slotIndex, durationSlots *int
		var articleURL, articleLabel, videoURL, videoLabel *string
		var roomName, trackGroup *string
		var colorToken string

		if err := rows.Scan(
			&dayID, &date, &label, &startMinute, &cfgTZ,
			&sessionID, &kind, &title, &description, &category,
			&trackID, &roomID, &slotIndex, &durationSlots,
			&articleURL, &articleLabel, &videoURL, &videoLabel,
			&roomName, &colorToken, &trackGroup,
		); err != nil {
			return nil, err
		}

		// conference_config.timezone is the source of truth; the env venueTZ/loc
		// is only a fallback for an empty value (the column is NOT NULL, so this
		// is defensive).
		tz := r.venueTZ
		loc := r.loc
		if cfgTZ != "" {
			tz = cfgTZ
			loc = locationFor(cfgTZ)
		}

		agenda, ok := byDay[dayID]
		if !ok {
			agenda = &models.EventAgenda{
				ID:       dayID,
				EventID:  configID,
				Timezone: tz,
				Date:     date.Format("2006-01-02"),
				Sessions: make([]models.Session, 0),
			}
			if label != nil {
				agenda.Name = *label
			}
			byDay[dayID] = agenda
			order = append(order, dayID)
		}

		// LEFT JOIN yields one all-NULL session row for a day with no
		// sessions; skip it so the day still appears with an empty slice.
		if sessionID == nil {
			continue
		}

		session := models.Session{
			ID:            *sessionID,
			DayID:         dayID,
			DurationSlots: *durationSlots,
			SlotIndex:     slotIndex,
		}
		if kind != nil {
			session.Kind = *kind
		}
		if title != nil {
			session.Title = *title
		}
		if description != nil {
			session.Description = *description
		}
		if category != nil {
			session.Category = *category
		}
		if trackID != nil {
			session.TrackID = *trackID
		}
		if roomID != nil {
			session.RoomID = *roomID
		}
		session.ColorToken = colorToken
		if roomName != nil {
			session.RoomName = *roomName
		}
		if trackGroup != nil {
			session.TrackGroup = *trackGroup
		}
		if articleURL != nil {
			session.ArticleURL = *articleURL
		}
		if articleLabel != nil {
			session.ArticleLabel = *articleLabel
		}
		if videoURL != nil {
			session.VideoURL = *videoURL
		}
		if videoLabel != nil {
			session.VideoLabel = *videoLabel
		}

		if slotIndex != nil {
			start, end := computeSessionWindow(date, startMinute, *slotIndex, *durationSlots, r.slotMinutes, loc)
			session.StartTime = &start
			session.EndTime = &end
		}

		agenda.Sessions = append(agenda.Sessions, session)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	sessionIDs := make([]string, 0)
	for _, id := range order {
		for _, s := range byDay[id].Sessions {
			sessionIDs = append(sessionIDs, s.ID)
		}
	}
	speakers, err := fetchSessionSpeakers(ctx, r.pool, r.piiKey, sessionIDs)
	if err != nil {
		return nil, err
	}

	result := make([]models.EventAgenda, 0, len(order))
	for _, id := range order {
		agenda := byDay[id]
		for i := range agenda.Sessions {
			// Left nil, not an empty slice, when a session has no speakers:
			// omitempty then drops the key rather than shipping "speakers": []
			// on every break and registration row.
			agenda.Sessions[i].Speakers = speakers[agenda.Sessions[i].ID]
		}
		result = append(result, *agenda)
	}
	return result, nil
}
