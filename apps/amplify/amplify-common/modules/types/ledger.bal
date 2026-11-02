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

// Points ledger row and its reference (C2). Shared because amplify-jobs awards engagements and
// amplify-api awards external shares and writes corrections.

import ballerina/crypto;
import ballerina/time;
import ballerina/uuid;

# Ledger reference: `AMP-`, `ADJ-` or `REV-` plus a suffix (`points_ledger.reference`, `varchar(66)`).
public type LedgerReference string;

# Prefix of an award row.
public const string AWARD_PREFIX = "AMP-";
# Prefix of a PO adjustment row.
public const string ADJUSTMENT_PREFIX = "ADJ-";
# Prefix of a reversal row.
public const string REVERSAL_PREFIX = "REV-";
# Column size of `points_ledger.reference` (C1).
public const int LEDGER_REFERENCE_MAX_LENGTH = 66;
# Length of every award reference: `AMP-` + 43 base64url characters of a sha256 digest.
public const int AWARD_REFERENCE_LENGTH = 47;

# Points earned from an engagement fact.
public const ENGAGEMENT = "ENGAGEMENT";
# Points earned from an approved external share.
public const EXTERNAL_SHARE = "EXTERNAL_SHARE";
# PO adjustment.
public const ADJUSTMENT = "ADJUSTMENT";
# Reversal of an earlier row.
public const REVERSAL = "REVERSAL";

# What produced a ledger row (`source_type`).
public type LedgerSourceType ENGAGEMENT|EXTERNAL_SHARE|ADJUSTMENT|REVERSAL;

# Valid points waiting for Coin issue. Phase 1 default for awards.
public const HELD = "HELD";
# Converted to Coins (phase 2; blocked by a `CHECK` in phase 1).
public const PAID = "PAID";

# Settlement status. `()` means action required.
public type LedgerStatus HELD|PAID;

# Actor id written on rows the system produces.
public const string SYSTEM_ACTOR = "system";

# One append-only ledger row. Only the settlement fields (`status`, `statusChangedAt`, `paidAt`,
# `coinReference`) may change after insert.
public type LedgerEntry record {|
    # Primary key
    LedgerReference reference;
    # Who the points belong to
    EmployeeId employeeId;
    # Campaign, when the row relates to one
    string? campaignId;
    # What produced the row
    LedgerSourceType sourceType;
    # Engagement or external share id; `()` for adjustments and reversals
    string? sourceId;
    # Priced action; `()` for adjustments and reversals
    PointAction? action;
    # Signed points
    int points;
    # Rule that priced the award; `()` for adjustments and reversals
    string? ruleId;
    # Reference this row cancels (reversals only)
    LedgerReference? reversesReference;
    # Required for adjustments and reversals
    string? reason;
    # `system` or the PO's employee id
    string actorId;
    # Request or run correlation id
    string? correlationId;
    # Insert time
    time:Utc createdAt;
    # Settlement status, `()` = action required
    LedgerStatus? status;
    # When the status last changed
    time:Utc? statusChangedAt;
    # When it was paid (phase 2)
    time:Utc? paidAt;
    # Coin transaction reference (phase 2)
    string? coinReference;
|};

# Deterministic award reference (C1): `AMP-` + unpadded base64url of
# sha256(`provider` LF `target` LF `employeeId` LF `action`). Always 47 characters, so it fits
# `varchar(66)` (hex would be 68). Re-running a score pass gives the same key, so the insert is
# `ON CONFLICT DO NOTHING`. The encoding is revisited after phase 1 against wso2-coin (C1).
#
# + provider - Provider of the resource or evidence (`linkedin`, `medium`, `other`)
# + target - Target resource URN, or the normalized evidence URL
# + employeeId - Who earns the points
# + action - Priced action
# + return - The reference, or `INVALID_LEDGER_REFERENCE` when a part is blank, holds a line feed or has
# surrounding whitespace (hashing ` x` and `x` to two references would let one action earn twice)
public isolated function awardReference(string provider, string target, EmployeeId employeeId, PointAction action)
        returns LedgerReference|DomainError {
    foreach string part in [provider, target, employeeId] {
        if part.trim().length() == 0 || part.includes("\n") || part.trim() != part {
            return domainError(ERR_INVALID_LEDGER_REFERENCE,
                    "Award reference parts must be non-blank, trimmed single lines");
        }
    }
    byte[] digest = crypto:hashSha256(string:'join("\n", provider, target, employeeId, action).toBytes());
    return AWARD_PREFIX + toBase64Url(digest);
}

# Adjustment reference: `ADJ-` + a UUIDv7.
#
# + id - UUIDv7, for example from `newUuidV7()`
# + return - The reference, or `INVALID_UUID`
public isolated function adjustmentReference(string id) returns LedgerReference|DomainError {
    string checked = check parseUuidV7(id);
    return ADJUSTMENT_PREFIX + checked;
}

# Reversal reference: `REV-` + a UUIDv7.
#
# + id - UUIDv7, for example from `newUuidV7()`
# + return - The reference, or `INVALID_UUID`
public isolated function reversalReference(string id) returns LedgerReference|DomainError {
    string checked = check parseUuidV7(id);
    return REVERSAL_PREFIX + checked;
}

# Checks a ledger reference read from outside (for example a path parameter).
#
# + raw - Reference to check
# + return - The reference, or `INVALID_LEDGER_REFERENCE`
public isolated function parseLedgerReference(string raw) returns LedgerReference|DomainError {
    string value = raw.trim();
    if value.length() > LEDGER_REFERENCE_MAX_LENGTH
            || !(re `AMP-[A-Za-z0-9_\-]{43}`.isFullMatch(value)
                || re `(ADJ|REV)-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`.isFullMatch(value)) {
        return domainError(ERR_INVALID_LEDGER_REFERENCE, "Ledger reference is not valid");
    }
    return value;
}

# Unpadded base64url (RFC 4648 §5).
#
# + bytes - Bytes to encode
# + return - Encoded text
public isolated function toBase64Url(byte[] bytes) returns string {
    string encoded = bytes.toBase64();
    encoded = re `\+`.replaceAll(encoded, "-");
    encoded = re `/`.replaceAll(encoded, "_");
    return re `=+$`.replaceAll(encoded, "");
}

# New UUIDv7 (RFC 9562): 48-bit Unix milliseconds, then random bits taken from a v4 UUID
# (`SecureRandom`). Ballerina's uuid module has no v7, and the plan rules out v4 for ids.
#
# + return - Lowercase UUIDv7 text
public isolated function newUuidV7() returns string {
    time:Utc now = time:utcNow();
    int millis = now[0] * 1000 + <int>(now[1] * 1000d).floor();
    string ts = int:toHexString(millis);
    while ts.length() < 12 {
        ts = "0" + ts;
    }
    ts = ts.substring(ts.length() - 12);
    string rnd = re `-`.replaceAll(uuid:createType4AsString(), "");
    int variantBits = checkpanic int:fromHexString(rnd.substring(0, 1)) & 3;
    string variant = int:toHexString(8 + variantBits);
    string hex = ts + "7" + rnd.substring(13, 16) + variant + rnd.substring(17, 32);
    return string `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${
        hex.substring(16, 20)}-${hex.substring(20, 32)}`;
}

# Checks a UUIDv7.
#
# + raw - UUID text
# + return - Lowercased UUID, or `INVALID_UUID`
public isolated function parseUuidV7(string raw) returns string|DomainError {
    string value = raw.trim().toLowerAscii();
    if !re `[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`.isFullMatch(value) {
        return domainError(ERR_INVALID_UUID, "Id must be a UUIDv7");
    }
    return value;
}
