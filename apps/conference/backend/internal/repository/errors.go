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

import "errors"

// ErrNotFound is returned by repository methods when a requested row does
// not exist (or, for session lookups, exists but is not in a usable state
// for the query being performed, e.g. an unscheduled session).
var ErrNotFound = errors.New("not found")

// ErrInvalidCursor is returned by paginated repository methods when the
// opaque pagination cursor supplied by the client cannot be decoded. Handlers
// map it to 400 Bad Request rather than 500, since it's a malformed client
// input, not an internal fault.
var ErrInvalidCursor = errors.New("invalid pagination cursor")

// ErrDuplicateAllocation is returned by CoinAllocationRepo.Insert when the
// (qr_id, user_uuid) unique constraint is violated. Insert can hit this even
// after a preceding Exists check passed, since two concurrent scans of the
// same QR by the same user can both pass Exists before either has inserted.
var ErrDuplicateAllocation = errors.New("coin allocation already exists for this qr_id and user_uuid")

// ErrSelfConnection is returned by ConnectionRepo.Request when the requester
// and the addressee are the same person. The user_connection_no_self CHECK
// refuses the row anyway; this turns that into a distinguishable error rather
// than an opaque constraint violation, so the handler can answer 400 instead
// of 500.
var ErrSelfConnection = errors.New("cannot connect to yourself")

// ErrConnectionForbidden is returned when the caller is a party to a
// connection but not the party allowed to make the transition they asked for
// -- in practice, a requester trying to accept their own request. Handlers
// map it to 403.
//
// A caller who is not a party at all gets ErrNotFound instead, deliberately:
// answering 403 there would confirm to a stranger that the id exists.
var ErrConnectionForbidden = errors.New("caller may not perform this transition")

// ErrConnectionNotPending is returned by ConnectionRepo.Accept when the row
// exists and the caller really is its addressee, but the connection has
// already moved on (it is accepted). Handlers map it to 409 Conflict: the
// request was legitimate, it just lost a race or was replayed.
var ErrConnectionNotPending = errors.New("connection is not pending")
