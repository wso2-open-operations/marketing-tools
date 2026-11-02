# marketing-tools
Open Source tools beneficial to marketing domain.

## Apps

```
apps/
├── amplify/        # WSO2 Amplify: employees amplify WSO2's LinkedIn posts, earn points, see leaderboards (Ballerina backend + local stack)
├── conference/     # WSO2Con conference backend (Go)
└── registrant/     # Conference attendee registration app backend (Go)
```

| App | What it is | Start here |
|---|---|---|
| [amplify](apps/amplify) | Backend for WSO2 Amplify: amplify-api, amplify-jobs, scheduler, database migrations, shared Ballerina packages, and a full local Docker stack. The UI lives in One WSO2 (`webapp/src/features/amplify`). | [apps/amplify/README.md](apps/amplify/README.md) |
| [conference](apps/conference/backend) | WSO2Con conference backend | [openapi.yaml](apps/conference/backend/openapi.yaml) |
| [registrant](apps/registrant/backend) | Conference attendee registration app | [openapi.yaml](apps/registrant/backend/openapi.yaml) |

Each app keeps its Choreo component descriptors (`.choreo/component.yaml`) inside its own folder.
