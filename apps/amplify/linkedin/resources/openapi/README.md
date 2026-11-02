# LinkedIn OpenAPI specs

One OpenAPI 3.0.3 file per LinkedIn Postman collection, in `openapi/`. They are a reading aid for the LinkedIn APIs
Amplify touches (and the ones it might later), not a contract LinkedIn publishes. The source collections are in
`../postman-exports/`. The specs were produced from them once, on 2026-10-15, and are maintained by hand from now on. There is no generator
in the repo, so when LinkedIn's collections change, edit the YAML (or redo the conversion) and update the notes below.

| Spec | Covers |
| --- | --- |
| `w-member-social.openapi.yaml` | Share on LinkedIn (`w_member_social`), the scope Amplify posts with |
| `member-posts-management.openapi.yaml` | Member posts |
| `community-management.openapi.yaml` | Community Management |
| `content-apis.openapi.yaml` | Content APIs |
| `campaign-management.openapi.yaml`, `reporting-roi.openapi.yaml`, `media-planning.openapi.yaml` | Advertising: campaigns, reporting, media planning |
| `audiences.openapi.yaml`, `audience-insights.openapi.yaml` | Audiences and audience insights |
| `lead-sync.openapi.yaml`, `conversions-api.openapi.yaml` | Lead sync, conversions |
| `company-intelligence-api.openapi.yaml`, `events-management-api.openapi.yaml`, `lms-api-siteup.openapi.yaml`, `people-typeahead-mention-search-api.openapi.yaml` | The smaller APIs |

## How the collections were converted

- **Base URL.** `https://api.linkedin.com/rest`, assumed, because `{{baseUrl}}` is not defined in the collections.
  `/me` carries a `/v2` server override.
- **Auth.** A collection with OAuth settings gets an `authorizationCode` flow with LinkedIn's authorization and token
  URLs and the scopes the collection lists. The others get bearer auth. `LinkedIn-Version` and
  `X-Restli-Protocol-Version` are shared header parameters.
- **Paths.** `{{vars}}`, literal IDs and URNs in a path became typed path parameters, for example
  `/adAccounts/{adAccountId}/adCampaigns/{adCampaignId}`. Composite keys such as `(account:...,user:...)` became a
  single `...Key` parameter.
- **Finders and actions.** An OpenAPI path can't hold several operations that differ only by `?q=` or `?action=`.
  Each path and method is one operation, `q` and `action` are enum selectors, and each Postman variant is listed in
  the description. `adAnalytics` is the extreme case: 27 requests folded into one operation.
- **Batch calls.** `X-RestLi-Method` (batch create, batch get and so on) is an enum header.
- **Request bodies** are inferred from the saved examples. Four collections held invalid JSON in saved bodies
  (missing commas, `...` placeholders); those were repaired where possible.
- **Responses** are inferred from the saved responses, so every field is optional and undocumented. A call with no
  saved example gets an inferred success code, marked as inferred in its description. One shared `Error` response
  covers the errors.
- **Uploads.** The `PUT {{upload_url}}` steps became a `/dms-uploads/{uploadPath}` operation on `www.linkedin.com`.
- **Redaction.** Signed query strings on upload URLs were redacted in the example responses, and the files were
  scanned for emails and tokens.

All specs pass `openapi-spec-validator`.

## Open questions

Check these against LinkedIn's documentation before relying on the specs for them:

- A few legacy-looking calls (`/shares`, `/adCampaigns`, `/adCreatives`, `/creatives`) sit under the same base URL but
  may belong under `/v2`.
- Content APIs has one request with an empty URL; it was skipped.
- Two Content APIs requests use `{shared ID}/{ugcPosts ID}` in the path, which became `/posts/{postId}/{postId2}`.
  What that endpoint really is has not been confirmed.
- Three Media Planning requests and the four Audience Insights POST examples are merged under shared selectors, so
  their request examples are named but not split into separate operations.
