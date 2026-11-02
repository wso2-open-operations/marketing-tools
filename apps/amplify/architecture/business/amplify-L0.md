# WSO2 Amplify — L0 Solution View

Source: `docs/requirements/0 PO Team _ WSO2 Amplify - Tracking Platform Requirements.md`

```text
                              WSO2 AMPLIFY · L0 SOLUTION VIEW
                                 Employee advocacy tracking platform

 ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐
 │   Marketing & PO   │ │     Employees      │ │     PO (Admin)     │ │   SLT & Everyone   │
 │   content owners   │ │    830+, opt-in    │ │  programme owner   │ │      viewers       │
 └─────────┬──────────┘ └─────────┬──────────┘ └─────────┬──────────┘ └─────────┬──────────┘
           │ register             │ link profile         │ tune points          │ view boards
           │ official posts       │ submit own posts     │ fix records          │ & reports
           │                      │ see points & coins   │                      │
 ┌─────────▼──────────────────────▼──────────────────────▼──────────────────────▼──────────┐
 │                                                                                         │
 │                                AMPLIFY TRACKING PLATFORM                                │
 │                                                                                         │
 │   ┌───────────────────┐       ┌───────────────────┐       ┌───────────────────┐         │
 │   │ 1 · PUBLISH       │       │ 2 · CONNECT       │       │ 3 · TRACK         │         │
 │   │ Post registry     │ ────► │ Profile linking   │ ────► │ Activity capture  │         │
 │   │ category, priority│       │ opt-in via SSO    │       │ reacts, reposts,  │         │
 │   │                   │       │                   │       │ own-post submits  │         │
 │   └───────────────────┘       └───────────────────┘       └─────────┬─────────┘         │
 │                                                                     │                   │
 │   ┌───────────────────┐       ┌───────────────────┐       ┌─────────▼─────────┐         │
 │   │ 6 · CELEBRATE     │       │ 5 · REWARD        │       │ 4 · SCORE         │         │
 │   │ Leaderboards      │ ◄──── │ Points → Coins    │ ◄──── │ Points engine     │         │
 │   │ Reports: team,    │       │ Personal history  │       │ 1x per action/post│         │
 │   │ location, post    │       │                   │       │ Admin adjustments │         │
 │   └───────────────────┘       └───────────────────┘       └───────────────────┘         │
 │                                                                                         │
 │   ┌───────────────────────────────────────────────────────────────────────────────┐     │
 │   │      GOVERNANCE (all stages): opt-in · minimum data · no duplicate credit     │     │
 │   │         full audit log · channel-agnostic (more social channels later)        │     │
 │   └───────────────────────────────────────────────────────────────────────────────┘     │
 │                                                                                         │
 └─────────┬──────────────────────┬──────────────────────┬──────────────────────┬──────────┘
           │ announce             │ sign-in &            │ engagement           │ credit
           │ new posts            │ identity             │ activity             │ coins
 ┌─────────▼──────────┐ ┌─────────▼──────────┐ ┌─────────▼──────────┐ ┌─────────▼──────────┐
 │  Team Chat Space   │ │ Identity Provider  │ │   Social Network   │ │ Rewards Programme  │
 │  (announcements)   │ │  (single sign-on)  │ │ (posts & activity) │ │  (existing coins)  │
 └────────────────────┘ └────────────────────┘ └────────────────────┘ └────────────────────┘

 Legend:  [ ] actor (top) / external system (bottom)   1–6 platform stages   ──► flow
```
