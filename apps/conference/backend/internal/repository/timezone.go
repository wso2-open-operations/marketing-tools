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
	"sync"
	"time"
)

// locCache memoizes time.LoadLocation, which reads the tzdata files on each
// call. Conference timezones are a tiny, stable set, so this stays small.
var locCache sync.Map // string -> *time.Location

// locationFor loads the IANA timezone named tz, the per-event value read from
// conference_config.timezone (the real upstream column -- the sole source of
// truth for how session instants are anchored, per the user decision). An
// empty or unloadable value falls back to UTC rather than erroring: a single
// bad config row must not 500 an entire agenda.
func locationFor(tz string) *time.Location {
	if tz == "" {
		return time.UTC
	}
	if v, ok := locCache.Load(tz); ok {
		return v.(*time.Location)
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	locCache.Store(tz, loc)
	return loc
}

// resolveLoc picks the location for a session whose owning conference_config
// timezone column scanned to cfgTZ. The column is authoritative; fallback is
// used only when the column is NULL/empty (the column is NOT NULL, so this is
// defensive), and is itself UTC when no fallback is configured.
func resolveLoc(cfgTZ *string, fallback *time.Location) *time.Location {
	if cfgTZ != nil && *cfgTZ != "" {
		return locationFor(*cfgTZ)
	}
	if fallback != nil {
		return fallback
	}
	return time.UTC
}
