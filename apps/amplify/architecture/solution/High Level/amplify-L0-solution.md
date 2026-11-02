# WSO2 Amplify — L0 Solution View

Sources: `docs/requirements/0 PO Team _ WSO2 Amplify - Tracking Platform Requirements.md`, weekly status report.

```text
                                  WSO2 AMPLIFY · L0 SOLUTION VIEW

             ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
PEOPLE       │    Employees     │  │  Marketing & PO  │  │     PO Admin     │  │       SLT        │
             │   830+, opt-in   │  │   post owners    │  │ programme owner  │  │    leadership    │
             └──────────────────┘  └──────────────────┘  └──────────────────┘  └──────────────────┘
                       │                     │                     │                     │
                       └────────┬────────────┴─────────────────────┴────────┬────────────┘
                                ▼                                           ▼
             ┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
             │ CHAT ASSISTANT                       │    │ EMPLOYEE PORTAL                      │
CHANNELS     │ announcements · Q&A                  │    │ leaderboards · personal history      │
             │ own-post submission                  │    │ dashboards & reports                 │
             │ team chat space app                  │    │ admin: posts, points, corrections    │
             └──────────────┬───────────────────────┘    └─┬────┬─────────────────────────┬─────┘
                            │                              │    │                         │
                            │       ┌──────────────────────┘    │                         │SSO
                            │       │                           │                         ▼
             ┏━━━━━━━━━━━━━━┿━━━━━━━┿ WSO2 AMPLIFY [NEW SYSTEM] ┿━━━━━━━┓   ┌─────────────────────┐
             ┃              ▼       ▼                           ▼       ┃   │ IDENTITY PROVIDER   │
             ┃  ┌──────────────────────┐     ┌────────────────────────┐ ┃   │ [CONFIG]            │
             ┃  │ AMPLIFY AGENT        │     │ BACK-OFFICE            │ ┃   │ SSO · employee to   │
             ┃  │ employee help        │     │ post registry          │─╂──►│ social account link │
AMPLIFY      ┃  │ own-post intake      │◄───►│ engagement tracking    │ ┃   │                     │
             ┃  │ AI writing assist    │     │ scoring 1x/action      │ ┃   └─────────────────────┘
             ┃  │ hosted in Amplify    │     │ points ledger          │ ┃
             ┃  │                      │     │ audit log              │ ┃
             ┃  └──────────────────────┘     └────┬─────────────────┬─┘ ┃
             ┃                                    │                 │   ┃
             ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━┿━━━┛
                                                  │engagement       │ issue coins
                                                  │                 └─────────────┐
                                                  ▼                               ▼
                              ┌────────────────────────────┐    ┌────────────────────────────────┐
                              │ SOCIAL NETWORK  [EXTERNAL] │    │ REWARDS SYSTEM  [DEPENDENCY]   │
                              │ posts & engagement data    │    │ issues coins from points       │
SYSTEMS                       │ ⚠ API approval pending     │    │ ⚠ in business design           │
                              │   (mock endpoints for now) │    │   (points held in ledger)      │
                              └────────────────────────────┘    └────────────────────────────────┘

[DEPENDENCY] new system, other team   ⚠ tracked risk
```

## L1 bridge: abstract component → concrete system

L0 keeps product names out on purpose. This table is the hand-off to L1.

| L0 component | System | Change type | Owner |
| --- | --- | --- | --- |
| WSO2 Amplify (Agent + Back-office) | WSO2 Amplify | New system | Developer |
| Chat Assistant | Google Chat app "Novera" (PO Agent repo) | Update | Visal Rajapakse |
| Employee Portal | One WSO2 | Add features | Developer |
| Identity Provider | Asgardeo (WSO2 production) | Add config | Developer |
| Social Network | LinkedIn Community Management API | External vendor | Developer |
| Rewards System | WSO2 Coins | New system, other team | Nikeshala Samanthilake (business), technical TBD |
| *(out of scope)* | Agent Orchestrator | n/a | Visal Rajapakse |
