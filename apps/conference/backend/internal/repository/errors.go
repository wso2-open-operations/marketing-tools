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

// ErrDuplicateAllocation is returned by CoinAllocationRepo.Insert when the
// (qr_id, user_uuid) unique constraint is violated. Insert can hit this even
// after a preceding Exists check passed, since two concurrent scans of the
// same QR by the same user can both pass Exists before either has inserted.
var ErrDuplicateAllocation = errors.New("coin allocation already exists for this qr_id and user_uuid")
