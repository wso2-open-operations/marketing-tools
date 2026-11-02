# Runbook: Rate limiting for the APIs Amplify uses

Status: Draft (2026-10-21). Owner: Amplify technical owner. Pairs with [resilience-targets.md](resilience-targets.md) (what degrades and how) and [choreo-deploy.md](choreo-deploy.md) (D2 sets the proxy limits).

Amplify touches three rate-limited surfaces. Two are limits we **meet** (LinkedIn, Google Chat). One is a limit we **set** (the API proxy in front of `amplify-api`). This runbook covers the numbers, where to set or check each one, what Amplify does today when it hits one, and what is still open.

**How sure are the numbers?** Each row says where it came from. "Documented" means a vendor page states it. "Not published" means the vendor says to look it up in a console. "Open" means we haven't confirmed it, and the plan has a todo.

## 1. The limits at a glance

| Surface | Limit | Resets | Source |
| --- | --- | --- | --- |
| LinkedIn, Share on LinkedIn (`w_member_social`), **per member** | 150 requests per day | Midnight UTC | Documented ([Share on LinkedIn](https://learn.microsoft.com/linkedin/consumer/integrations/self-serve/share-on-linkedin)) |
| LinkedIn, Share on LinkedIn, **per application** | 100,000 requests per day | Midnight UTC | Documented (same page) |
| LinkedIn, `POST /rest/posts` specifically | Not published. The limits table above is on the Share on LinkedIn page, which describes the older `ugcPosts` call | Midnight UTC | **Open.** LinkedIn says standard limits are shown in the Developer Portal ([Rate Limiting](https://learn.microsoft.com/linkedin/shared/api-guide/concepts/rate-limits)) |
| Google Chat, writes **per space** | 1 per second, shared by every Chat app in the space | Rolling | Documented ([Chat API usage limits](https://developers.google.com/workspace/chat/limits)) |
| Google Chat, writes **per project** | 3,000 per minute | Rolling | Documented (same page) |
| Google Chat, incoming webhooks | "Additional limits apply"; the numbers aren't on that page | n/a | **Open** |
| API proxy (Choreo) on `amplify-api` | Whatever we set, per API and per operation | Per window we choose | We set it (section 4). What the 429 looks like is **open** |

## 2. LinkedIn

### What LinkedIn does

- Two daily limits apply: **application** (everything our app does) and **member** (one employee's token through our app). Both reset at midnight UTC.
- Over a limit, LinkedIn returns **429**. Two messages matter for posting:
  - `UGC action was blocked because a share limit has been reached`: the author (the employee) hit their daily share limit.
  - `Resource level throttle {period} limit for calls to this resource is reached`: the application hit its limit on that resource.
- LinkedIn can also return 429 for its own infrastructure protection. That clears by itself.
- We have not found a `Retry-After` header in LinkedIn's documentation. Don't depend on one.
- Developer Admins get an **email at 75% of an application-level limit**. The email arrives 1 to 2 hours late, and it covers only application-level limits, never member-level ones.

### Setup checklist

- [ ] **L1** In the [Developer Portal](https://www.linkedin.com/developers/apps), open the Amplify app (non-prod first, then prod) › **Analytics**. Make one real `POST /rest/posts` first (a share through Amplify counts), then refresh. The page only lists endpoints called at least once that UTC day. Record the application and member limits for `POST /rest/posts` in section 5.
- [ ] **L2** Make sure the Developer Admins on the app include a team mailbox, not just one person, so the 75% alert reaches someone on a day off.
- [ ] **L3** Set `linkedinMaxPostsPerDay` (amplify-jobs, default 1000) **below** the application limit from L1. It counts published shares per UTC day across Runs and defers the rest. Today's default of 1000 is far under the 100,000 documented for Share on LinkedIn, but L1 may show a different number for `/rest/posts`.
- [ ] **L4** Decide whether a per-member ceiling is needed. One employee reposting 150 campaign posts in a day is unlikely, so the pilot probably doesn't need it. Amplify has **no per-member counter** today (one share per person per campaign limits it indirectly).
- [ ] **L5** After the pilot's first week, compare real peak daily posts to the limit and write the headroom in section 5.

### What Amplify does today on a 429

`amplify-jobs` treats a LinkedIn 429 as retryable: the share stays `QUEUED` and the outbox retries it with backoff (30 s, doubling, capped at 3600 s, 8 attempts). The LinkedIn breaker opens when at least half of at least 5 calls in 60 seconds fail (429 and 5xx count, 403 does not) and tries again after 30 seconds.

**Gap: a daily-limit 429 doesn't wait for midnight.** All 8 attempts fit inside roughly an hour, so a limit hit in the afternoon ends in `RETRIES_EXHAUSTED` and the employee has to ask again. The fix is in the plan ("Rate limit (429) handling"): treat a daily-limit 429 as a deferral until after 00:00 UTC (with jitter), without using up attempts, and honor a `Retry-After` header when one is sent.

### When you see it

| Symptom | Check | Action |
| --- | --- | --- |
| Run log shows `deferred` rising and `linkedinPosts` near the per-run or daily ceiling | `linkedinMaxPostsPerRun` (50), `linkedinMaxPostsPerDay` | Expected. Rows are due again later. Raise the ceiling only if L1 shows room |
| Shares end `FAILED` with reason `RETRIES_EXHAUSTED` and code `RATE_LIMITED` | `sharing.share_request`, Developer Portal Analytics | A daily limit was hit. After 00:00 UTC the employee can request again (a failed share retries on the same row) |
| Run log `breakers` shows `linkedinApi: OPEN` | LinkedIn status, Developer Portal | Wait: it half-opens after 30 s and one trial call decides. Nothing to reset by hand |
| 75% email from LinkedIn | Developer Portal Analytics | Look at the day's volume. If real demand, lower the per-run ceiling so posts spread out |

## 3. Google Chat

### What Google does

- **1 write per second per space.** The limit is shared with every other Chat app in that space, so a busy space can push Amplify over it even at low volume.
- **3,000 writes per minute per project.**
- A violation returns **429**. Google asks for exponential backoff: wait `min(2^n + up to 1 s of random, max)`, with a max of 32 or 64 seconds, and cap the number of retries.
- Incoming webhooks have extra limits that Google's quota page doesn't list.

### Setup checklist

- [ ] **G1** Leave `chatMinIntervalSeconds` at **1**. It spaces the card posts one second apart, which keeps Amplify at the per-space limit.
- [ ] **G2** In the WSO2 Club space, check what else posts there. If other bots are busy, expect occasional 429s and leave the outbox retry as it is.
- [ ] **G3** Record the webhook's actual limit if Google publishes one: see [Build a Google Chat app as a webhook](https://developers.google.com/chat/how-tos/webhooks).

### What Amplify does on a 429

The announcement is retried by the outbox with backoff, up to the same 8 attempts, then `FAILED` with an admin retry (`/admin/announcements/{id}/retry`). A card goes out once per campaign, so volume is low: one card per registered post.

To test locally: `curl -X PUT localhost:9095/stub/status/429` makes the chat stub answer 429 (`200` resets it). Details in [google-chat-webhook.md](google-chat-webhook.md).

## 4. The API proxy in front of amplify-api

This is the limit we **set**. One WSO2 calls only the proxy (ADR-004), so a rate limit here protects `amplify-api`, the database and the LinkedIn daily budget.

### What Choreo gives us

- Rate limits can be set at the **API** level and the **operation** (resource) level. Choreo's changelog says custom limits at those two levels replace subscription- and application-level throttling ([Custom Rate Limit Support](https://wso2.com/choreo/changelog/custom-rate-limit-support/)).
- **That means one shared counter for all employees.** A low limit on `POST /campaigns/{id}/shares` is not "per person". If everyone clicks Amplify after a Club announcement, they share one budget. Set limits for the whole company at peak, not for one user.
- **Open:** the exact 429 response (body, and whether `Retry-After` or rate-limit headers come back) isn't in the Choreo documentation we could reach. See checklist P4.

### Setup checklist

- [ ] **P1** Decide the pilot's peak: how many employees might click Amplify within a minute after a Club card goes out. Ask the PO team for the pilot headcount.
- [ ] **P2** In the proxy (choreo-deploy D2), set limits per operation, not one number for the whole API. Placeholder starting points, **not measured**: reads (`GET`) generous, writes tighter, shares and external shares the tightest. Fill in the table in section 5 with the real values and the reason.
- [ ] **P3** Leave `/health` and `/ready` unpublished ([resilience-targets.md](resilience-targets.md)), so no rate limit is needed on them.
- [ ] **P4** Make the response visible: in the proxy test console, lower one operation's limit to 1 per minute, call it twice, and record the **status, body and headers** of the 429 in section 5. Then restore the limit. This tells us whether One WSO2 can read a wait time.
- [ ] **P5** Run the load tests (`scripts/load-test.sh`, `scripts/load`) against the proxy limits in a non-prod environment and write down at what rate the first 429 appears.

### What One WSO2 does on a 429 today

Nothing special. The Amplify screens don't read `Retry-After` or retry, so a throttled click shows a generic error and the employee has to try again. The plan item "Rate limit (429) handling" covers this: read the wait time, show "Too many requests, try again in N seconds", and retry once after the wait. A retried `POST` must reuse its `Idempotency-Key`, so a second try can't queue two shares.

## 5. Values to fill in (record them here)

| Item | Value | Date | By |
| --- | --- | --- | --- |
| LinkedIn app limit for `POST /rest/posts` (non-prod) | _open (L1)_ | | |
| LinkedIn member limit for `POST /rest/posts` (non-prod) | _open (L1)_ | | |
| LinkedIn app and member limits (prod) | _open (L1)_ | | |
| `linkedinMaxPostsPerDay` / `linkedinMaxPostsPerRun` set to | 1000 / 50 (defaults) | 2026-10-21 | |
| Google Chat webhook limit (if published) | _open (G3)_ | | |
| Proxy limit per operation (reads / writes / shares) | _open (P2)_ | | |
| Proxy 429: status, body, `Retry-After` present? | _open (P4)_ | | |

## 6. Related

- [resilience-targets.md](resilience-targets.md) §5 for what each dependency's outage looks like to users
- [google-chat-webhook.md](google-chat-webhook.md) for the webhook setup and the chat stub
- ADR-025 (retries go through the outbox, never at the HTTP level for posts)
- Plan: M9, "Rate limit (429) handling"
- LinkedIn: [Rate Limiting](https://learn.microsoft.com/linkedin/shared/api-guide/concepts/rate-limits), [Share on LinkedIn](https://learn.microsoft.com/linkedin/consumer/integrations/self-serve/share-on-linkedin), [Posts API](https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api)
- Google: [Chat API usage limits](https://developers.google.com/workspace/chat/limits)
- Choreo: [Custom Rate Limit Support](https://wso2.com/choreo/changelog/custom-rate-limit-support/)
