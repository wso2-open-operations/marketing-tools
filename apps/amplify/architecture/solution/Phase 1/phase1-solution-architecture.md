# WSO2 Amplify: Phase 1 Solution Architecture

Logical view (audit D1): contexts, cell edge, deployables and externals. No Choreo specifics; see [phase1-domains.md](phase1-domains.md) for the contexts and [phase1-planned-todos.md](../../../docs/requirements/phase1-planned-todos.md#architecture-at-a-glance) for the deployment view. For how the code modules stack and connect, see [phase1-code-modules.md](phase1-code-modules.md).

```mermaid
flowchart TB
    classDef people fill:#1f2a44,stroke:#8aa0c8,color:#ffffff
    classDef channel fill:#13203d,stroke:#ff7300,color:#ffffff
    classDef edge fill:#ff7300,stroke:#ff7300,color:#0b1530,font-weight:bold
    classDef deploy fill:#1b2b52,stroke:#ffffff,color:#ffffff
    classDef ctx fill:#22355f,stroke:#8aa0c8,color:#ffffff
    classDef store fill:#0f1c38,stroke:#8aa0c8,color:#ffffff
    classDef ext fill:#2a2f3a,stroke:#9aa3b5,color:#ffffff,stroke-dasharray: 5 3

    subgraph PEOPLE["People"]
        EMP["Employee<br/>connect · share · External Sharing"]
        MKT["Marketing · PO<br/>register campaigns"]
        PO["PO team<br/>review · adjust · point rules · dashboard"]
        ADM["Admin<br/>settings · kill switches · run schedule"]
    end

    subgraph ONEWSO2["One WSO2 (existing)"]
        UI["Amplify module<br/>Posts · Leaderboard · My Campaign · Team<br/>Campaigns · PO Review · Admin"]
        SSO["Asgardeo SSO<br/>roles from amplify_* groups"]
    end

    subgraph CELL["Amplify cell (owns its data)"]
        PROXY["Amplify API Proxy<br/>single ingress · auth · scopes · rate limit"]
        subgraph API["amplify-api"]
            S1["S1 Campaign"]
            S2["S2 LinkedIn Connection"]
            C1A["C1 Sharing (requests)"]
            S3["S3 External Sharing"]
            C2A["C2 Scoring (PO corrections)"]
            S4["S4 Recognition<br/>3 leaderboards · PO dashboard"]
        end
        subgraph JOBS["amplify-jobs (one worker)"]
            C1J["C1 provider adapter<br/>publish shares"]
            S5["S5 Announcements<br/>chat notifier"]
            C2J["C2 score pass"]
            MNT["daily maintenance<br/>partitions · outbox purge"]
        end
        SCHED["Scheduler (akornatskyy/scheduler, ADR-026)<br/>internal only · no API auth<br/>POST /runs · /maintenance/partitions"]
        SDB[("Scheduler DB<br/>own database + user")]
        DB[("PostgreSQL<br/>schema per context · outbox<br/>encrypted tokens (daily partitions)<br/>append-only ledger · audit")]
    end

    LI["LinkedIn<br/>OAuth + OIDC · Share on LinkedIn<br/>w_member_social"]
    GC["Google Chat<br/>WSO2 Club Group<br/>incoming webhook"]

    EMP --> UI
    MKT --> UI
    PO --> UI
    ADM --> UI
    UI -. sign-in .-> SSO
    UI -->|"HTTPS · Asgardeo bearer · OpenAPI"| PROXY
    PROXY --> API
    API -->|"Save & Share Now"| JOBS
    API -->|"schedule sync (jobs upsert)"| SCHED
    SCHED -->|"cron / @every"| JOBS
    SCHED --> SDB
    API --> DB
    JOBS --> DB
    S2 -->|"OAuth code exchange"| LI
    C1J -->|"POST /rest/posts"| LI
    S5 -->|"cardsV2"| GC
    GC -. "card opens share page" .-> UI

    subgraph LATER["Later phases (not built in phase 1)"]
        L1["Community Management sync · share verification · metrics"]
        L2["Coin issuer · SLT reports · HR data"]
        L3["Agent (Novera, AMP) · other platforms · data-deletion path"]
    end

    class EMP,MKT,PO,ADM people
    class UI,SSO channel
    class PROXY edge
    class SCHED deploy
    class S1,S2,C1A,S3,C2A,S4,C1J,S5,C2J,MNT ctx
    class DB,SDB store
    class LI,GC,L1,L2,L3 ext
```
