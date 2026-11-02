# WSO2 Amplify — L1 Solution Architecture

Builds on: [L0 Solution View](amplify-L0-solution.md)
Sources: `docs/requirements/0 PO Team _ WSO2 Amplify - Tracking Platform Requirements.md`, weekly status report.

```text
                                         WSO2 AMPLIFY · L1 SOLUTION ARCHITECTURE

              ┌────────────────────┐     ┌────────────────────┐     ┌────────────────────┐      ┌────────────────────┐
PEOPLE        │     Employees      │     │   Marketing & PO   │     │      PO Admin      │      │        SLT         │
              │    830+, opt-in    │     │   register posts   │     │   points & fixes   │      │      reports       │
              └────────────────────┘     └────────────────────┘     └────────────────────┘      └────────────────────┘
                         │                          │                          │                           │
                         └──────────┬───────────────┴──────────────────────────┴──────────┬────────────────┘
                                    ▼                                                     ▼
              ┌──────────────────────────────────────────┐    ┌───────────────────────────────────────────────────────┐
              │ GOOGLE CHAT                     [UPDATE] │    │ ONE WSO2                                        [ADD] │
              │ Amplify space                            │    │ Amplify pages:                                        │
CHANNELS      │ Novera app (PO Agent repo)               │    │ · leaderboards (individual, team) · my points & coins │
              │ · new-post announcements                 │    │ · dashboards: team, location, post                    │
              │ · ask Amplify · submit own post          │    │ · admin: posts, point values, corrections             │
              └───────────────┬──────────────────────────┘    └───┬─────────────┬───────────────────────────┬─────────┘
                              │                                   │             │                           │
                              │chat + announcements               │             │pages & admin              │SSO
                              │           ┌───────────────────────┘             │                           │
              ┏━━━━━━━━━━━━━━━┿━━━━━━━━━━━┿━ WSO2 AMPLIFY  [NEW SYSTEM] ━━━━━━━━┿━━━━━━━━━━━━┓              │
              ┃               ▼           ▼                                     ▼            ┃              ▼
              ┃  ┌────────────────────────────┐        ┌──────────────────────────────────┐  ┃    ┌───────────────────┐
              ┃  │ AMPLIFY AGENT              │        │ AMPLIFY API                      │  ┃    │ ASGARDEO [CONFIG] │
              ┃  │ chat help for employees    │        │ posts · profiles · scores        │  ┃    │ WSO2 production   │
WSO2          ┃  │ own-post intake            │◄──────►│ leaderboards · reports           │  ┃link│ SSO: One WSO2     │
AMPLIFY       ┃  │ hosted in Amplify          │        │ admin & corrections              │◄─╂────│ LinkedIn account  │
              ┃  │ (no Agent Orchestrator)    │        │ chat announcements               │  ┃    │ link (federated)  │
              ┃  └────────────────────────────┘        └───────┬──────────────────────────┘  ┃    └─────────┬─────────┘
              ┃                                                │                             ┃              │
              ┃                                                ▼                             ┃              │
              ┃  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┃              │
              ┃  │ ENGAGEMENT    │  │ SCORING       │  │ AMPLIFY DB    │  │ COIN ISSUER   │  ┃              │
              ┃  │ SYNC          │  │ ENGINE        │  │ posts · links │  │ reads ledger  │  ┃              │
              ┃  │ scheduled     │─►│ tier rules    │─►│ points ledger │─►│ waits until   │  ┃              │
              ┃  │ pull per post │  │ 1x per action │  │ audit log     │  │ Coins ready   │  ┃              │
              ┃  │               │  │               │  │               │  │               │  ┃              │
              ┃  └───────┬───────┘  └───────────────┘  └───────────────┘  └───────┬───────┘  ┃              │
              ┃          │                                                        │          ┃              │
              ┗━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━┛              │
                         │                                                        │                         │
                         │reactions, comments,  ┌─────────────────────────────────┼─────────────────────────┘
                         │reposts               │                                 │   member sign-in
                         │                      │                                 │
                         ▼                      ▼                                 ▼
              ┌────────────────────────────────────────────┐        ┌────────────────────────────┐
              │ LINKEDIN                        [EXTERNAL] │        │ WSO2 COINS    [DEPENDENCY] │
SYSTEMS       │ WSO2 company page + "WSO2 Amplify" app     │        │ new system, other team     │
              │ Community Management API                   │        │ ⚠ in business design       │
              │ ⚠ approval pending: build against mocks    │        │    points held in ledger   │
              │    made from the LinkedIn OpenAPI specs    │        │    until Coins is ready    │
              └────────────────────────────────────────────┘        └────────────────────────────┘


[NEW] built here   [ADD]/[UPDATE]/[CONFIG] change to existing system   [DEPENDENCY] new system, other team
⚠ tracked risk     Out of scope: WSO2 Agent Orchestrator (no phase-1 ETA)
```

## High-level integration flow

| # | Stage | Flow |
| --- | --- | --- |
| 1 | Publish | Marketing & PO register an official LinkedIn post (category, priority) in One WSO2 admin → Amplify API → Amplify DB. |
| 2 | Publish | Amplify API pushes a new-post announcement to the Amplify space through the Novera Google Chat app. |
| 3 | Connect | Employee signs in to One WSO2 with Asgardeo, then links their LinkedIn account through Asgardeo's federated LinkedIn sign-in. Amplify stores the employee ↔ LinkedIn member link. |
| 4 | Track | Engagement Sync pulls reactions, comments and reposts for each registered post from the LinkedIn Community Management API on a schedule, and matches actors to linked employees. |
| 5 | Track | Employee submits an original WSO2 post through Novera or One WSO2 → Amplify Agent → Amplify API for higher-tier points. |
| 6 | Score | Scoring Engine applies tier rules once per action per post per person and writes to the points ledger. Every change goes to the audit log. PO Admin can change point values and correct records from One WSO2. |
| 7 | Reward | Coin Issuer reads the ledger and issues coins in WSO2 Coins. Until Coins is ready, points accumulate in the ledger. |
| 8 | Celebrate | One WSO2 shows leaderboards, personal history and dashboards from the Amplify API. |

## Systems in scope

| System | Role in Amplify | Change type | Owner |
| --- | --- | --- | --- |
| WSO2 Amplify | Agent, API, back-office jobs, data | New system | Developer |
| Google Chat · Novera (PO Agent repo) | Announcements, chat access to the Amplify Agent | Update | Visal Rajapakse |
| One WSO2 | Leaderboards, dashboards, admin screens, agent access | Add features | Developer |
| Asgardeo (WSO2 production) | SSO, LinkedIn account linking | Add config | Developer |
| LinkedIn Community Management API | Post engagement data | External vendor | Developer |
| WSO2 Coins | Coin issuance | New system, other team | Nikeshala Samanthilake (business), technical TBD |
| WSO2 Agent Orchestrator | *Out of scope:* no phase-1 ETA | n/a | Visal Rajapakse |

## Assumptions

- Amplify runs on Choreo. Amplify API is TypeScript (same as the PO Agent) on PostgreSQL. One WSO2 pages are React.
- LinkedIn account linking runs through Asgardeo as a federated LinkedIn connection. Confirmed: the LinkedIn sign-in member ID matches the Community Management actor URN.
- Amplify sends Google Chat announcements through the existing Novera app, not a separate bot.


