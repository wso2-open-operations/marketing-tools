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

// Stable domain error codes. The API (M5) returns these as the `code` of an error body.

// Value objects
public const ERR_INVALID_EMPLOYEE_ID = "INVALID_EMPLOYEE_ID";
public const ERR_INVALID_EMAIL = "INVALID_EMAIL";
# A sign-in whose email belongs to a different, still separate employee record (not a re-created account of the same person).
public const ERR_EMAIL_CONFLICT = "EMAIL_CONFLICT";
public const ERR_INVALID_MEMBER_URN = "INVALID_MEMBER_URN";
public const ERR_INVALID_POST_URN = "INVALID_POST_URN";
public const ERR_INVALID_EVIDENCE_URL = "INVALID_EVIDENCE_URL";
public const ERR_EVIDENCE_URL_NOT_HTTPS = "EVIDENCE_URL_NOT_HTTPS";
public const ERR_EVIDENCE_URL_TOO_LONG = "EVIDENCE_URL_TOO_LONG";
public const ERR_EVIDENCE_URL_CREDENTIALS = "EVIDENCE_URL_CREDENTIALS";
public const ERR_EVIDENCE_URL_IP_HOST = "EVIDENCE_URL_IP_HOST";
public const ERR_INVALID_LEDGER_REFERENCE = "INVALID_LEDGER_REFERENCE";
public const ERR_INVALID_UUID = "INVALID_UUID";

// Shared
public const ERR_VERSION_CONFLICT = "VERSION_CONFLICT";
public const ERR_NOT_FOUND = "NOT_FOUND";

// S1 Campaign
public const ERR_CAMPAIGN_ALREADY_REGISTERED = "CAMPAIGN_ALREADY_REGISTERED";
public const ERR_NOT_WSO2_RESOURCE = "NOT_WSO2_RESOURCE";
public const ERR_INVALID_CAMPAIGN = "INVALID_CAMPAIGN";
public const ERR_INVALID_WINDOW = "INVALID_WINDOW";
public const ERR_CAMPAIGN_ARCHIVED = "CAMPAIGN_ARCHIVED";
public const ERR_CAMPAIGN_NOT_OPEN = "CAMPAIGN_NOT_OPEN";
public const ERR_POST_HAS_ACTIVITY = "POST_HAS_ACTIVITY";

// S2 Connection
public const ERR_MISSING_SCOPE = "MISSING_SCOPE";
public const ERR_MEMBER_ALREADY_LINKED = "MEMBER_ALREADY_LINKED";
public const ERR_CONNECTION_REMOVED = "CONNECTION_REMOVED";
public const ERR_CONNECTION_NEEDS_RECONNECT = "CONNECTION_NEEDS_RECONNECT";

// C1 Sharing
public const ERR_SHARE_ALREADY_QUEUED = "SHARE_ALREADY_QUEUED";
public const ERR_SHARE_ALREADY_PUBLISHED = "SHARE_ALREADY_PUBLISHED";
public const ERR_SHARE_NOT_QUEUED = "SHARE_NOT_QUEUED";
public const ERR_COMMENTARY_REQUIRED = "COMMENTARY_REQUIRED";
public const ERR_COMMENTARY_NOT_ALLOWED = "COMMENTARY_NOT_ALLOWED";
public const ERR_COMMENTARY_TOO_LONG = "COMMENTARY_TOO_LONG";

// S3 External Sharing
public const ERR_CERTIFICATION_REQUIRED = "CERTIFICATION_REQUIRED";
public const ERR_EVIDENCE_ALREADY_CLAIMED = "EVIDENCE_ALREADY_CLAIMED";
public const ERR_NOT_PENDING = "NOT_PENDING";
public const ERR_SELF_REVIEW = "SELF_REVIEW";
public const ERR_REASON_REQUIRED = "REASON_REQUIRED";
public const ERR_NOT_APPROVED = "NOT_APPROVED";
public const ERR_ALREADY_AMPLIFIED = "ALREADY_AMPLIFIED";

// C2 Scoring
public const ERR_RULE_NOT_FOUND = "RULE_NOT_FOUND";
public const ERR_RULE_VERSION_EXISTS = "RULE_VERSION_EXISTS";
public const ERR_RULE_BACKDATED = "RULE_BACKDATED";
public const ERR_INVALID_POINTS = "INVALID_POINTS";
public const ERR_TOP_UP_NOT_POSITIVE = "TOP_UP_NOT_POSITIVE";
public const ERR_ALREADY_REVERSED = "ALREADY_REVERSED";
public const ERR_CANNOT_REVERSE_REVERSAL = "CANNOT_REVERSE_REVERSAL";
public const ERR_PAID_NOT_ALLOWED = "PAID_NOT_ALLOWED";

// S5 Announcements
public const ERR_ALREADY_ANNOUNCED = "ALREADY_ANNOUNCED";
public const ERR_ANNOUNCEMENT_NOT_QUEUED = "ANNOUNCEMENT_NOT_QUEUED";
public const ERR_ANNOUNCEMENT_NOT_FAILED = "ANNOUNCEMENT_NOT_FAILED";
