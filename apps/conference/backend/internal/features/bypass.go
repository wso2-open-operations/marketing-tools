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
	"strings"
)

// GateBypassEmailsKey is the app_config row listing the callers for whom a
// disabled feature's routes answer anyway.
//
// The problem it solves: `is_<feature>_enabled` does two jobs at once. The
// microapp reads it to hide the screen, and middleware.FeatureGate reads it to
// close the routes behind that screen -- which is the right pairing for an
// attendee and the wrong one for whoever has to test the endpoints before the
// feature is announced. With one flag there is no state that means "the screen
// stays hidden but the API answers me": turning the flag on to test it also
// puts the screen in front of every attendee.
//
// This row separates the two for named callers only. The flag stays '0', so
// every microapp still hides the screen; the addresses listed here get past
// the gate. Everyone else keeps getting the 503 and its coming-soon copy, so
// the flag has not been weakened for anybody who is not on the list.
//
// The value is addresses separated by commas, semicolons or newlines --
// whatever a human editing the row by hand reaches for:
//
//	'visalr@wso2.com, someone.else@wso2.com'
//
// Matching is against the JWT `email` claim, case-folded, because no IdP in
// front of this service treats an address as case-sensitive even though the
// RFC lets it. There is no wildcard: `*` is not a pattern here, it is an
// address that no token will ever carry. Opening every endpoint to every
// caller is not a bypass, it is turning the flags off, which is what an
// UPDATE on the `is_<feature>_enabled` rows already does.
//
// An absent or empty row means the bypass is off, which is the posture this
// service had before the row existed. No migration in this repository seeds
// the key: the row is created by hand, per environment, because its value
// names people, and an allowlist committed to source control is one that
// outlives whoever needed it. So there is nothing here for a fresh database
// to be behind on -- an unseeded environment is the switched-off state.
//
// The row is deliberately NOT returned by GET /app-configs -- it holds real
// addresses and that endpoint answers every authenticated attendee. See
// handlers.redactedConfigKeys.
const GateBypassEmailsKey = "feature_gate_bypass_emails"

// parseBypassEmails turns the stored list into a case-folded set. A missing,
// empty or all-separators value yields an empty set, i.e. nobody bypasses --
// the safe direction for a row whose whole job is to let requests through.
//
// Nothing here validates that an entry looks like an address: a typo'd entry
// simply matches no token, and the failure the operator sees is "I still get
// a 503", which points at the row. Rejecting the row wholesale on one bad
// entry would instead revoke the bypass for the addresses that were spelled
// correctly.
func parseBypassEmails(raw string) map[string]struct{} {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		switch r {
		case ',', ';', '\n', '\r', '\t', ' ':
			return true
		}
		return false
	})

	out := make(map[string]struct{}, len(fields))
	for _, f := range fields {
		if f = strings.ToLower(strings.TrimSpace(f)); f != "" {
			out[f] = struct{}{}
		}
	}
	return out
}

// BypassesGates reports whether email is on the GateBypassEmailsKey allowlist,
// i.e. whether this caller should be served a feature that is switched off.
//
// Reads through the same TTL-cached snapshot as Gate, so adding an address
// takes effect within DefaultTTL and a database outage leaves the last known
// list in force rather than either opening or closing the gate unexpectedly.
//
// An empty email is never on the list, however the row is spelled. That is the
// case where the token carried no `email` claim, and an unidentified caller is
// exactly who this must not let through.
func (r *Resolver) BypassesGates(ctx context.Context, email string) bool {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return false
	}

	bypass := r.load(ctx).bypass
	if len(bypass) == 0 {
		return false
	}
	_, ok := bypass[email]
	return ok
}
