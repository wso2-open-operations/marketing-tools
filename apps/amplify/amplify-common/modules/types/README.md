# amplify_common.types

Shared vocabulary for every Amplify component: the domain error, value objects with their parsers, the evidence URL parser, ledger types and shared enums. Pure functions and types, no I/O.

## Domain error and codes

Files: `modules/types/domain.bal`, `modules/types/error_codes.bal`.

- `DomainError` (`distinct error<DomainErrorDetail>`) carries a stable `code` that is safe to return to API callers. Build one with `domainError(code, message)`.
- `error_codes.bal` holds one `ERR_*` constant per code (for example `ERR_EVIDENCE_ALREADY_CLAIMED`, `ERR_SHARE_ALREADY_QUEUED`, `ERR_RULE_BACKDATED`), grouped by context: identity values, campaign, connection, sharing, external sharing, scoring, announcements.
- The message never carries tokens or commentary.

## Value objects

File: `modules/types/value_objects.bal`.

- Types: `EmployeeId`, `MemberUrn`, `PostUrn`, `OrganizationUrn` (all strings, checked by their parsers).
- Parsers: `parseEmployeeId`, `parseEmail`, `parseMemberUrn`, `memberUrnFromSub`, `parsePostUrn`, `parseOrganizationUrn`. They return the value or a `DomainError`.
- Helpers: `resourceTypeOf` (URN to `ResourceType`), `isHttpsUrl`, `isIpLiteralHost`.
- Limits: `EMPLOYEE_ID_MAX_LENGTH`, `URN_MAX_LENGTH`, `EMAIL_MAX_LENGTH`.

## Shared enums and helpers

File: `modules/types/domain.bal`.

Enums are const unions, not Ballerina enums, because several contexts reuse the same member names.

- `Provider`, `ProviderApi`, `ResourceType`
- `ShareKind` (`REPOST`, `REPOST_COMMENTARY`, `SHARE`, `SHARE_COMMENTARY`), `EngagementAction`, `ExternalAction`, `PointAction`
- `FailureReason` (`NEEDS_RECONNECT`, `PROVIDER_REJECTED`, `RETRIES_EXHAUSTED`), `EngagementOrigin`
- Helpers: `hasCommentary`, `isBefore`, `addDays`, `trimToNil`, `SECONDS_PER_DAY`.

File: `modules/types/types.bal` holds `HealthState` (`UP`, `DOWN`) and `HealthStatus` for the health and readiness probes.

## Evidence URL

File: `modules/types/evidence_url.bal`.

- `parseEvidenceUrl(raw)` returns an `EvidenceUrl` (`normalized`, `submitted`, `host`, `provider`, `resourceUrn`) or a `DomainError`.
- Rules: HTTPS only, at most `EVIDENCE_URL_MAX_LENGTH` (2048) characters, no user info, DNS host name (no IP literal, no single label). Normalization lowercases scheme and host, drops default port, fragment and trailing slashes, strips tracking parameters and sorts the query.
- A LinkedIn URL that names a post URN normalizes to the canonical feed URL of that URN, so both LinkedIn URL forms claim one post.
- `linkedInPostEvidenceUrl(postNumber)` builds the canonical URL. Provider names: `EVIDENCE_PROVIDER_LINKEDIN`, `EVIDENCE_PROVIDER_MEDIUM`, `EVIDENCE_PROVIDER_OTHER`.
- Amplify never fetches the URL.

## Ledger types and references

File: `modules/types/ledger.bal`.

- `LedgerEntry` is one append-only ledger row. Only the settlement fields (`status`, `statusChangedAt`, `paidAt`, `coinReference`) change after insert.
- `LedgerSourceType` (`ENGAGEMENT`, `EXTERNAL_SHARE`, `ADJUSTMENT`, `REVERSAL`), `LedgerStatus` (`HELD`, `PAID`), `SYSTEM_ACTOR`.
- `LedgerReference` and its builders: `awardReference` (`AMP-` + base64url of a SHA-256, always 47 characters, deterministic so a re-run inserts nothing new), `adjustmentReference` (`ADJ-` + UUIDv7), `reversalReference` (`REV-` + UUIDv7), `parseLedgerReference`.
- `newUuidV7`, `parseUuidV7`, `toBase64Url`.

## Depends on

Nothing in this package. Uses `ballerina/time` and `ballerina/crypto`.

## Does not do

- No persistence and no network calls.
- No scoring rules or point values (those are in `amplify_domain.scoring`).
- No HTTP status mapping for error codes (that is in `amplify-api`).

## Tests

`modules/types/tests/`: `value_objects_test.bal`, `evidence_url_test.bal`, `ledger_test.bal`. Run `bal test` from `amplify-common`.
