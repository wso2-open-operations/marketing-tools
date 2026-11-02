// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
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

// Which employee a verified token is. A re-created Asgardeo account (new `sub`, same email) resolves to the
// person's first employee id (V020 alias), so the ledger, standings and audit keep one key. See
// `identity:resolveEmployee` for the rules.

import amplify_api.auth;
import amplify_common.types;
import amplify_domain.identity;

import ballerina/time;

# How long a resolved `sub` is reused, seconds. Memory only. A clash (`EMAIL_CONFLICT`) is never reused.
configurable decimal identityCacheSeconds = 300;

# Most `sub` values kept; past it the expired ones go, then everything (a flood of new subs is not a leak).
const int IDENTITY_CACHE_MAX = 20000;

isolated map<[types:EmployeeId, decimal]> resolvedSubs = {};

# The employee id a verified caller acts as.
#
# + p - Caller, `employeeId` still the token's `sub`
# + return - The employee id, `EMAIL_CONFLICT` as a domain error for a genuine clash, or an error (database)
isolated function canonicalEmployeeId(auth:Principal p) returns types:EmployeeId|types:DomainError|error {
    decimal now = time:monotonicNow();
    lock {
        [types:EmployeeId, decimal]? hit = resolvedSubs[p.employeeId];
        if hit is [types:EmployeeId, decimal] && now - hit[1] < identityCacheSeconds {
            return hit[0];
        }
    }
    identity:ResolvedEmployee|types:DomainError resolved = check identity:resolveEmployee(check employeeRepository(),
            p.employeeId, p.email);
    if resolved is types:DomainError {
        return resolved;
    }
    lock {
        if resolvedSubs.length() >= IDENTITY_CACHE_MAX {
            foreach [string, [types:EmployeeId, decimal]] [k, v] in resolvedSubs.entries() {
                if now - v[1] >= identityCacheSeconds {
                    _ = resolvedSubs.remove(k);
                }
            }
            if resolvedSubs.length() >= IDENTITY_CACHE_MAX {
                resolvedSubs.removeAll();
            }
        }
        resolvedSubs[p.employeeId] = [resolved.employeeId, now];
    }
    return resolved.employeeId;
}
