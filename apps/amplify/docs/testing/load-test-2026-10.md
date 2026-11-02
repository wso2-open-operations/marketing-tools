# Load test, October 2026 (plan M11)

> Newer run: [JMeter, 19 October 2026](jmeter-2026-10-19.md), every module with p95/p99, after the move to marketing-tools.

**Target:** p95 < 50 ms for `/leaderboard`, `/me/points` and `/team` (One WSO2 speed, plan M3 note), with 1,000 employees and 50,000 ledger rows.

**Result on local Compose:** `/leaderboard` and `/me/points` meet it with room to spare (p95 10–20 ms). `/team` (PO company view, 25 rows a page) sits right on the line: p95 50 ms in one run, 77 ms in the other. The database isn't the bottleneck (the page query runs in 0.2 ms); the time is in the api process and the laptop's Docker VM. Re-measure in Choreo dev before calling `/team` done.

## Setup

| | |
|---|---|
| Date | 2026-10-17 |
| Stack | `make up` (local Compose, ADR-027 images), Postgres 18, one amplify-api replica, no JVM flags (defaults) |
| Host | MacBook, Docker Desktop VM with 6 CPUs / 16 GB, shared with a k3d cluster and other containers |
| Data | `scripts/load/seed-load.sql`: 1,000 employees (`lt-0001`..`lt-1000`), 50,000 `ENGAGEMENT` ledger rows over six months, then `POST /maintenance/rebuild-recognition` (1,001 standings) |
| Tool | k6 1.0.0 (`grafana/k6` image on the Compose network, nothing installed on the host), `scripts/load/amplify-load.js` |
| Load | constant arrival rate, 50 req/s per endpoint (150 req/s total) for 60 s, after a 30 s warm-up at the same rate |
| Callers | 200 employee dev JWTs (random per request) for `/leaderboard` and `/me/points`; one `amplify_po` JWT for `/team?page=0..39` (company view) |
| Run it | `make up && make load-test` (`RATE=… DURATION=…` to change), then `make down` |

## Results

Two back-to-back runs after the fixes below. Zero failed requests (9,003 and 9,001 requests, all 200).

| Endpoint | Run | median | p90 | **p95** | p99 | max | Target |
|---|---|---|---|---|---|---|---|
| `GET /leaderboard` | 1 | 2.1 ms | 7.9 ms | **12.1 ms** | 58.8 ms | 193 ms | met |
| | 2 | 2.7 ms | 11.7 ms | **20.5 ms** | 73.7 ms | 239 ms | met |
| `GET /me/points` | 1 | 1.8 ms | 6.8 ms | **10.5 ms** | 43.7 ms | 192 ms | met |
| | 2 | 2.2 ms | 9.8 ms | **17.3 ms** | 71.5 ms | 273 ms | met |
| `GET /team` (PO, 25/page) | 1 | 6.0 ms | 31.5 ms | **50.0 ms** | 119.6 ms | 254 ms | on the line |
| | 2 | 7.6 ms | 41.6 ms | **77.4 ms** | 153.4 ms | 336 ms | missed |

The proxy rate-limit half of the M11 load item isn't covered here: local Compose has no API proxy (the APIM profile waits on the non-prod Asgardeo org). It belongs to the Choreo dev run.

## What the first runs found (and what changed)

The first run (same data, same rate) gave p95 67 / 57 / 107 ms with p99 around 640 ms on all three endpoints. Three causes, all fixed in this milestone:

1. **A WARN log with a full error stack on every leaderboard/team read.** With `rosterUrl` unset (D13 still open), `rosterStatus()` logged "Team roster unavailable" per request: 3,400 stack-trace log lines in three minutes. Now "not configured" is a known state, logged once at startup, and a real roster failure logs only the reason.
2. **One settings query per request.** `loadSettings()` read `config.app_setting` every call. It now caches for `settingsCacheSeconds` (default 5 s; a save on the same replica drops the cache; other replicas see a change, kill switches included, within 5 s).
3. **Two window functions over every standing for the company view.** `teamPage()` computed `dense_rank()` and `count(*) OVER ()` across all 1,000 rows. When there is no roster filter and no search, the team rank is the stored company rank, so the query now pages straight off `standing_rank_idx` (domain IT covers both paths).

After (1) and (2), `/leaderboard` and `/me/points` dropped to p95 ~30 ms; the k6 warm-up was then lengthened from 10 s at 20 req/s to 30 s at the test rate, because the first measured seconds after a container start carried JIT warm-up.

## Where `/team` time goes

- `EXPLAIN ANALYZE` of the page query (generic plan, as the JDBC driver runs it after five executions): **0.2 ms** execution, index scan on `standing_rank_idx` + incremental sort.
- Postgres logged no statement over 20 ms during a run (`log_min_duration_statement = 20`), apart from the seed itself.
- Isolated at 50 req/s, `/team` with 10 rows a page had p95 16 ms; with 50 rows, p95 213 ms. Latency grows with rows on the page, not with the query.
- `/health` at 150 req/s: p95 3.5 ms, so the HTTP listener itself is fine.

So the cost is building and serializing the page in the api (per-row record mapping, the `json` response) plus run-to-run noise from a shared laptop VM. Median stays at 6–8 ms; the tail is the problem.

## Follow-ups

- [ ] Re-run in Choreo dev (plan M11 E2E/load line), through the API proxy, with the proxy rate limits on. That's the number that counts.
- [ ] If `/team` still misses there: return a typed record instead of `json` from `teamView` (skips a conversion), and add the leaderboard's `ETag` + `Cache-Control: private, max-age=30` on the standing version so One WSO2 revalidates with a cheap 304.
- [ ] JVM settings for the api image (`-XX:+UseZGC` or a fixed heap) only if the dev numbers show GC pauses in the tail.

Raw k6 summaries for both runs were taken from `scripts/load-test.sh` output; re-run any time with `make up && make load-test`.

## M11b: the `/team` tail was the JSON serializer's buffer growth on JDK 21

Appended 2026-10-17 (M11b). The M11 runs above left `/team` at p95 50–77 ms while its page query ran in
0.2 ms and Postgres logged nothing over 20 ms, so the cost was in the api process. It was not the query,
the auth path, the audit write or the connection pool: JFR on the api during the run put roughly three
quarters of its samples inside JSON serialization, and the rest of the request is common to `/leaderboard`
and `/me/points`, which were three to six times faster on the same listener with the same token path.
It was how the HTTP module writes the response body.

### Root cause

The http module serializes a `json` returned from a resource with
`JsonUtils.serialize(value, OutputStream)`. That overload builds its generator over the stream:
`new JsonGenerator(OutputStream)` → `new BufferedWriter(new OutputStreamWriter(out, charset))`. On the
image's JDK 21 (`eclipse-temurin:21-jre-alpine`, 21.0.12.1) `BufferedWriter(Writer)` sizes its char buffer
with `initialBufferSize()`, which returns **512 when the thread is virtual** (`VM.isBooted() &&
Thread.currentThread().isVirtual()`) and 8192 otherwise. Ballerina strands are virtual threads, so the
JSON writer starts with a 512-char buffer.

Its growth is exact-fit, not doubling:

```java
int required = nextChar + len + 1;
if (required > nChars && nChars < maxChars) {
    size = Math.min(required, maxChars);   // maxChars = 8192
    cb = Arrays.copyOf(cb, size);          // whole buffer copied, and never any spare room
    nChars = size;
}
```

So every write past 512 chars reallocates and copies the entire buffer, and the generator writes a value at
a time. A 25-row `/team` page is 6,178 bytes: a few thousand `Arrays.copyOf` calls of a growing array per
request, which is why latency scaled with rows on the page (16 ms at 10 rows, 213 ms at 50) and not with
anything Postgres does. JFR on the api during the M11 run put roughly half its samples in `Arrays.copyOf`
under `growIfNeeded` and about a quarter in `String.toCharArray` under `JsonGenerator.writeStringValue`,
which is the same loop seen from the other side.

There is no system property for this, and `toJsonString()` doesn't dodge it — `MapValueImpl.getJSONString()`
builds a `ByteArrayOutputStream` and takes the same `JsonGenerator(OutputStream)` path.

### The fix

`amplify-api/json_body.bal` (new) exposes `jsonText(json) returns string|error` and
`jsonBody(json) returns http:Response|error`. `jsonText` calls the runtime's own encoder through a
different overload — `JsonUtils.serialize(Object, Writer)` — passing a `java.io.StringWriter`. A
`StringWriter` is a `Writer`, so the `BufferedWriter` wrapper is never built, its `StringBuffer` doubles
instead of growing exact-fit, and **the bytes are the runtime's own output, not a hand-rolled encoder**.

`GET /team` now returns `jsonBody(<json>view)` instead of the bare `json` (the resource's union is
`json|http:Response|ProblemResponse|error`; `ProblemResponse` passes through untouched). The Java interop
follows the existing pattern in `amplify-common`'s `crypto/gcm.bal` — `handle` in and out, `java:toString`
to get the text, no new dependency (stdlib `ballerina/jballerina.java` only).

### Measurements

Same keep-alive sweep (k6 1.0.0 constant-arrival-rate, 50 req/s, 30 s after a 15 s warm-up, container CPU
from `/proc/1/stat` net of the idle background rate), before and after, same data, same host:

| Endpoint | rows/page | CPU ms/req before → after | median before → after | **p95 before → after** | p99 before → after |
|---|---|---|---|---|---|
| `GET /leaderboard` | – | 3.35 → 5.43 | 2.37 → 2.57 ms | **10.25 → 10.41 ms** | 21.6 → 17.8 ms |
| `GET /me/points` | – | 2.96 → 2.49 | 1.94 → 1.81 ms | **8.73 → 5.58 ms** | 16.4 → 9.1 ms |
| `GET /team` | 5 | 4.20 → 4.25 | 3.53 → 1.85 ms | **12.29 → 7.41 ms** | 18.5 → 13.3 ms |
| `GET /team` | 25 | 7.04 → 2.92 | 3.30 → 2.03 ms | **58.81 → 8.22 ms** | 123.0 → 20.6 ms |
| `GET /team` | 100 | 12.44 → 2.85 | 7.23 → 2.21 ms | **95.24 → 6.06 ms** | 186.5 → 12.0 ms |

CPU per request is only comparable in direction here (the after run's idle background rate was twice the
before run's, 18 vs 9 ms cpu/s, so the net figure is noisy). The latency columns are the point: **the
row-count scaling is gone** — 100 rows a page is now as fast as 5, where before it was 8× slower — and the
before run couldn't even hold 50 req/s at 100 rows (1,001 requests landed in 30 s of a 1,500-request
schedule; the after run did the full 1,500 with a clean median).

The official gate, `make load-test` (three endpoints at 50 req/s each, 150 req/s total, 60 s):

| Endpoint | p95 before → after | avg before → after | p99 before → after |
|---|---|---|---|
| `GET /leaderboard` | 9.95 → **6.77 ms** | 4.35 → 2.46 ms | 62.4 → 15.5 ms |
| `GET /me/points` | 8.74 → **6.00 ms** | 4.42 → 2.16 ms | 67.5 → 14.3 ms |
| `GET /team` (25/page) | 21.69 → **6.78 ms** | 8.56 → 2.63 ms | 127.9 → 15.1 ms |

9,002 requests, 100 % checks passed, 0 failures, all three `p(95)<50` thresholds green. `/leaderboard`
(687 B, so past the same 512-char window) improved the same way, which is consistent with the one
mechanism; `/me/points` is a smaller body and its move is closer to run noise. Either way, no endpoint
regressed.

### Behaviour is unchanged

The response body is a published contract, so it was pinned both ways:

- Five `/team` queries (size 5, 25, 100; `page=1&size=25`; `sort=name&q=Load`) captured before and after on
  the same seeded data, plus headers: **all five bodies byte-identical** (`cmp`), and headers identical
  apart from `date`/`X-Correlation-ID`, `content-type: application/json` and `content-length` included.
- `amplify-api/tests/json_body_test.bal` (new) asserts `jsonText(v) == v.toJsonString()` for empty,
  escaped (quote, backslash, newline, tab), non-ASCII, null-valued and nested/array values, and for a
  synthetic 25-row `/team` page, plus that `jsonBody` returns 200 with `application/json` and those exact
  bytes.

### Files changed

- `amplify-api/json_body.bal` — new: `jsonBody`, `jsonText` and the three Java interop declarations.
- `amplify-api/service.bal` — `GET /team` returns `jsonBody(<json>view)`.
- `amplify-api/tests/json_body_test.bal` — new: the equivalence test above.
- `amplify-api/Dependencies.toml` — the build's own update for the new direct `ballerina/jballerina.java` import.
- this file.

### Remaining risk

- Only `/team` moved onto `jsonBody`. It is the only phase-1 read whose body clears 1 KB; `/leaderboard`
  (687 B) crossed the 512-char window in the before run and is left as a follow-up rather than widened now,
  because each additional caller is another place the `json` return type changes. Any future read that pages
  many rows should use `jsonBody`, and the equivalence test is the guard for it.
- `java.io.StringWriter` holds the whole page as text in heap before the http module writes it (6 KB for a
  25-row page). That is smaller than the buffer churn it replaces, but for a much larger page (1,000 rows,
  an export) the memory cost is worth a second look — chunked writing would be the next step if that read
  ever appears.
- The typed-record suggestion in Follow-ups above won't help on its own: a record return is converted to
  `json` and serialized by the same generator.
- The local numbers still come from a shared laptop VM, and the row-count scaling is the only result here
  that is immune to that noise. Choreo dev through the proxy remains the gate that counts.
