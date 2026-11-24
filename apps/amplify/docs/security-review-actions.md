# Security review: actions and owners (2026-10-30)

What the code now does is in ADR-039 and ADR-040. This file lists every finding, whether it is done, and for the rest what to do and
who to ask. Findings that are infrastructure or process cannot be closed from this repository.

## Closed in code

| Finding | Severity | What changed |
| --- | --- | --- |
| amplify-jobs has no authentication | High | Shared `X-Amplify-Internal-Key`, fail closed, constant-time compare (ADR-039) |
| Chat webhook key and token on amplify-jobs trace spans (`http.url`), upstream PR 232 review | Medium | Closed. The `googlechat` module, its transport check and the webhook secret were removed. Novera is the only announcement channel, and jobs calls it with a bearer token, so no key or token sits in a URL that a trace could record |
| Interim deletion script fails (`email` is NOT NULL UNIQUE) and keeps the member URN | Medium | `identity.erase_employee` (V018), integration-tested; the runbook calls it |
| No outbox queue monitoring | Medium | Gauges, `/ready` block, warning log; alert rules in `operations.md` section 11 |
| `amplify_api` has broad grants on `provider_token` | Low | V017: API loses UPDATE, jobs loses INSERT. API keeps SELECT (revoke at LinkedIn) |
| Leavers keep tokens, rows and leaderboard entries | Medium | Directory sweep in jobs, off by default, DRY_RUN first, hard limits (ADR-040) |

## Needs an owner (not code)

| Finding | Severity | What to do | Who |
| --- | --- | --- | --- |
| Aiven PostgreSQL may be publicly reachable | High | Check the service's allowed IP ranges and public access; restrict to the Choreo egress addresses or a private link; keep `VERIFY_FULL` with the CA file (identity-setup section 12) | Platform + Aiven admin |
| Access tokens survive logout | Medium | In the Asgardeo org: check whether logout revokes tokens and set the access-token lifetime short (15 to 60 minutes); Amplify has no denylist | IAM admins |
| Non-prod runs on local ThunderID | Medium | Create the staging Asgardeo org and Choreo project; point `GATEWAYJWKSURL`, `GATEWAYISSUER`, `GATEWAYAUDIENCES` and the One WSO2 config at it (identity-setup A and C) | IAM + Amplify tech owner |
| Cloudflare WAF in front of One WSO2 and the proxy | Medium | Confirm the zone, managed rules and rate limits with Ops; record the answer in the threat model | Ops |
| MFA enforcement in the Asgardeo WSO2 org | Medium | Read the org's login-flow policy and confirm MFA for all users | IAM admins |
| Production DB plan, backups and restore test | Medium | Pick a plan with automated backups and point-in-time recovery; run a restore into a scratch database following `operations.md` section 8; write down the time it took | Platform + Amplify tech owner |
| Retention for LinkedIn URNs and leavers | Low | Decide the retention period and who triggers offboarding; set `leaverSweepMode` to DRY_RUN, review, then ERASE | Legal / Privacy + People Ops |
| Legal sign-off for automated reposts (LinkedIn API Terms 3.1, item 26) and URN retention after removal | Medium | Ask Legal for a written answer; the code removes the URN on erase but not on "Remove Connection" until they decide | Legal / Privacy |
| DPIA for ranked leaderboards (GDPR Art. 35(3)(a)) | Medium | Start the assessment; inputs are in the data model and ADR-035 | Privacy |
| Token retention (60 days) and old keys after rotation | Medium | Decide the window; destroy old keys once `token_rotation` reports nothing left, then expire backups holding them | Amplify tech owner + Security |
| Threat-model diagrams | Low | Move the Choreo proxy outside the cell; add the deletion, migration runner, rotation and repository flows | Amplify tech owner |
| Threat-model rows 4.8 and 3.7 after LinkedIn mentions and re-link (2026-11-24) | Low | Update the threat model (`docs/security/WSO2 Amplify Threat Model.docx` in the wso2-amplify workspace). Row 4.8, LinkedIn token, revoke and member data use: commentary goes out as LinkedIn little text with only `#tags` and resolved mentions kept and everything else escaped; a mention's name and member URN come from Amplify's own rows, never from the text; only linked colleagues whose connection is neither removed nor revoked can be mentioned, and the typeahead matches the directory name only; a 401, or a 403 whose body says the member's token lacks the permission, revokes the connection and deletes the token row; any other 403 fails only that share, and the same 403 for several members halts posting for the run; a late lost-connection event fails only shares requested before it. Row 3.7: one member URN per live connection (unique on rows that aren't removed), so a removed link frees the member to link again. Add `GET /mentions` to the data-flow table | Amplify tech owner |
| Colleagues can @mention a linked member | Low | A new use of the member URN and LinkedIn name collected to post on the member's own behalf. Needs a privacy and consent review under the consent copy item AMP-R6 (and whether to offer an opt-out). Not decided here | Privacy + Amplify tech owner |
| Campaign registration: a compromised editor could announce an unapproved post | Low | Decide whether a second approver is wanted; the org-URN check stays | Product owner |
| Two POs can adjust or reverse each other's points | Medium | Business rule first (second approver, or an alert on cross-adjustments); not changed here | Product owner + Security |
| Move the LinkedIn revoke into the worker | Low | Would remove the API's read access to tokens; changes the 503-on-revoke-failure behaviour, so needs a product decision | Amplify tech owner |
| Chat webhook key and token appear in amplify-jobs trace spans (accepted risk, 2026-11-01) | Low | Closed (2026-11-12). The webhook path was removed, so there is no webhook URL to expose. Kept as a record | Amplify tech owner (Scott) |
