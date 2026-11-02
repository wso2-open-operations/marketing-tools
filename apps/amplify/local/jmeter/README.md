# JMeter performance suite

One master test plan (`master.jmx`) that covers the Ballerina modules in this folder, with p95 and p99 per module and per endpoint. Runs against the local Compose stack, the same stack `scripts/load-test.sh` (k6) uses.

## Scope

| Module | Thread group | What it exercises | Why |
|---|---|---|---|
| amplify-api | `api` | Health and read endpoints: `/me`, `/me/points`, `/me/shares`, `/campaigns`, `/leaderboard`, `/tags`, `/categories` | HTTP surface of the published API |
| amplify-domain | `domain` | PO and team reads that run the bounded-context repositories: `/team`, `/team/{id}/history`, `/po/dashboard`, `/po/point-rules`, `/po/external-shares` | Library, no endpoint of its own. Its numbers come from the API reads that run its repositories |
| amplify-common | `common` | `/health`, unauthenticated `/me` (expects 401), unknown campaign (expects 404 problem details) | Library, no endpoint of its own. Reached through the shared edges |
| amplify-jobs | `jobs`, `jobs-maintenance`, `jobs-run` | `/health`, `/ready`, `POST /maintenance/partitions`, and opt-in `POST /runs` | HTTP worker, internal port 9091 |

Left out:

- **amplify-database**: SQL migrations, not Ballerina.
- **amplify-scheduler**: an image with no Ballerina code.

Every thread group is a separate JMeter thread group in the same plan, so they run in parallel. A module can run alone by setting the others to zero threads (`MODULES=...`).

## Prerequisites

- Docker, with the stack up: `make up` from `apps/amplify`. Only `amplify-api` is published to the host, so JMeter runs in a container on the `wso2-amplify_internal` network.
- `local/dev-jwt/` keys (created by `make up`).
- Python 3 on the host, for the summary.

## Run

```bash
local/jmeter/run.sh                                  # all modules, 120 s, p95 target 50 ms
MODULES="api domain" DURATION=300 local/jmeter/run.sh
RUN_JOBS=1 local/jmeter/run.sh                       # also POST /runs (drains the outbox)
SEED=0 local/jmeter/run.sh                           # keep the data already in the database
EXTRA_JMETER_ARGS="-Japi.threads=40 -Jthink.ms=0" local/jmeter/run.sh
```

`run.sh` checks that the stack is ready, seeds 1,000 employees and 50,000 ledger rows (the same seed as `scripts/load-test.sh`), mints 1 PO and `EMPLOYEES` (default 200) employee dev tokens, runs the plan, and prints the summary.

Knobs (environment variables): `MODULES`, `DURATION`, `RAMP`, `THINK_MS`, `EMPLOYEES`, `SEED`, `RUN_JOBS`, `P95_TARGET_MS`, `EXTRA_JMETER_ARGS`, `JMETER_IMAGE`. Any JMeter property can go through `EXTRA_JMETER_ARGS`, for example `-Japi.host=...`.

Dev tokens live 30 minutes, so `DURATION + RAMP` must stay under 1500 s. `run.sh` refuses longer runs.

## Read the result

Each run writes `local/jmeter/results/<timestamp>/`:

- `summary.md`: a table per module and per endpoint, with samples, error %, req/s, average, p50, p95, p99, max, and a verdict.
- `report/index.html`: the JMeter HTML dashboard, with percentiles, throughput over time, and error breakdown.
- `results.jtl` and `jmeter.log`: the raw samples.

The run exits non-zero when any endpoint's p95 is over `P95_TARGET_MS` (default 50 ms, the phase 1 read target from `scripts/load-test.sh`) or its error rate is over 0.1 %.

## Regenerate the plan

`master.jmx` is generated. To change the endpoints, thread counts, or assertions, edit `gen-master-plan.py` and regenerate:

```bash
python3 local/jmeter/gen-master-plan.py > local/jmeter/master.jmx
```

Labels are `<module>/<endpoint>`. `summarize.py` splits the percentiles by the part before the `/`.

## Caveats

- **Libraries are measured through the API.** amplify-domain and amplify-common have no HTTP surface, so the numbers for them are the numbers of the endpoints that run their code. A regression in a library shows up only where an endpoint exercises it.
- **Read-heavy by design.** The plan does not `POST /campaigns`, `POST /external-shares`, or the other write endpoints. Writes need valid category codes and fresh idempotency keys, and they change data on every run. Add them as a follow-up.
- **Assertions encode the contract.** Unauthenticated `/me` expects 401 and an unknown campaign expects 404. If the API returns something else, those endpoints show errors. That's a finding, not a test bug.
- **`POST /runs` has side effects.** It drains the outbox and posts to LinkedIn and chat-stub. It's off unless `RUN_JOBS=1`.
- **Local numbers are not production numbers.** Docker Desktop on a laptop, a single API replica, Postgres in a container, and the mock LinkedIn. Use them to compare runs against each other, and against the 50 ms target only as a rough guide.
- **amd64 image on arm64 hosts.** `justb4/jmeter:5.5` runs under emulation on Apple Silicon. That adds overhead to the load generator, so keep `THINK_MS` and the thread counts modest, and check that the generator isn't the bottleneck (JMeter's own CPU in `docker stats`).
