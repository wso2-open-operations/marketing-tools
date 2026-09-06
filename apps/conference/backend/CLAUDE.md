# Conference backend

Go service for the WSO2Con attendee app. Routes are mounted at the root and
served through a Choreo API gateway.

## Calling an Organization-visibility Choreo service

**Organization visibility restricts who can reach a component. It does not make
that component unauthenticated.** An Organization endpoint is still fronted by a
Choreo managed API gateway, and that gateway rejects a request carrying no
OAuth2 token — regardless of whether the service behind it checks anything.

This is counter-intuitive enough that it has cost real debugging time twice, so
it is written down here.

### The pattern that works

The reference implementation is `push-notification-gateway-api` →
`push-notification-service` in the `digiops-superapp` repo: a Public component
calling an Organization one. The engineer who directed this work reports that
pair works in production; the checkout itself cannot establish that (its `.env`
is `ENVIRONMENT=development`, with the production URL commented out). Copy its
shape.

1. **Point at the internal gateway URL**, version suffix included. Two host
   families have been observed, so take the URL from the callee's Choreo
   endpoint rather than pattern-matching:
   - `https://apis-internal.wso2.com/urwb/push-notification-service/v1.0` — the
     reference's internal URL, the only one it carries.
   - `https://<org-uuid>-<env>-internal.prod-internal.wdt.choreoapis.dev/<project>/<component>/v1.0`
     — the shape of the deployed `AI_SERVICE_URL` in this backend's staging
     environment. `<org-uuid>` is the organization's UUID, not its handle.

   There is no in-cluster address to use instead — `svc.cluster.local` appears
   nowhere in the reference, and the internal gateway host does not resolve off
   the dataplane, so it cannot be probed from a laptop.
2. **Send `Authorization: Bearer <token>`** from an OAuth2 `client_credentials`
   grant, with the client id and secret presented as HTTP Basic. The authority
   on the token endpoint is the `TokenURL` the Choreo Connection injects:
   Choreo derives it from the organization's APIM Key Manager, which is
   configurable per organization, so it is Asgardeo for some orgs and a Choreo
   STS for others. For **this** org it is verified to be
   `https://api.asgardeo.io/t/wso2/oauth2/token` — the working reference uses
   it, and so do the sibling integrations (`.claude/config.toml:104,108,112`).
   In this repo that means a `config.OAuthClientConfig` plus a
   `clientcredentials.Config`. `clients/aiagent` is the first client in this
   tree to pin `AuthStyle: oauth2.AuthStyleInHeader` explicitly;
   `clients/wallet`, `clients/qrportal`, `clients/transaction`,
   `clients/notification` and `clients/email` all leave it at the default
   `AuthStyleAutoDetect`.
3. **Subscribe the OAuth2 application to the callee's API** in the Choreo
   console. Creating a Choreo Connection is what creates the *subscription*,
   not merely the keys — hand-rolling a token skips that step. A valid id and
   secret whose application is not subscribed yields `900908`, not `900901`.
4. **Keep any caller-identity header separate.** `x-jwt-assertion` carries the
   attendee's own JWT and answers "who is asking"; the Bearer token answers "may
   this service call at all". They are not interchangeable and dropping either
   breaks a different thing.

None of this is checked in. `.choreo/component.yaml` schemaVersion 1.2 has no
endpoint-security field at all: a component's security settings are console-only
state, so they can silently differ from what any committed file implies. The
comment in `.choreo/component.yaml` can document the requirement; it cannot
enforce it.

### Reading the failures

Both gateways in the path emit a byte-identical
`401 {"error_message":"Invalid Credentials","code":"900901",...}` body, so the
body cannot tell you which one rejected you. The **headers** can:

| The front gateway | Tell |
|---|---|
| **Rejected** the request outright — your Bearer is bad, so nothing ran behind it | `www-authenticate: Bearer realm="Choreo Connect"` and `x-trace-key`; **neither** `x-envoy-upstream-service-time` nor `x-ratelimit-*` |
| **Forwarded** it — so the 401 came from this service or from a gateway further upstream | `x-envoy-upstream-service-time`; **no** `www-authenticate` |

Forwarded-versus-rejected is the whole discriminator; `x-ratelimit-*` is not one
on its own, since an ordinary 200 through this service's front gateway carries
it alongside the upstream-time header
(`.claude/prod-audit/raw/A_speakers_headers.txt:7-10`). The `www-authenticate`,
`x-trace-key` and upstream-time observations were captured live against the
staging gateway on 2026-09-06 — nothing in `.claude/` holds them.

Other gateway codes worth recognising, per `APISecurityConstants.java` in WSO2
`carbon-apimgt`:

- `900901` Invalid Credentials (401) — the gateway could not accept the token
  itself: wrong issuer or key manager, bad signature, malformed, or absent.
- `900902` Missing Credentials (401).
- `900906` No matching resource found in the API for the given request (404) —
  the path is not in the callee's deployed API definition, since a Choreo
  managed API only proxies paths its spec declares.
- `900908` Resource forbidden — subscription validation failed (403).

Latency is a second tell. An AI route that fails in single-digit milliseconds
never reached a model; it was refused at a gateway.

### Logs

`cmd/server/main.go:80-83` selects `slog.NewTextHandler` only for
`APP_ENV=development`; **every other value, unset included**, gets
`slog.NewJSONHandler` — so staging is no more exempt from what follows than
production is. The Choreo log viewer's summary line renders only slog's
**message**, dropping its attributes. An upstream status put in an attribute is
therefore invisible where people actually look. Put anything needed for
diagnosis in the message itself — `handlers.respondAIUpstreamError` does this
deliberately — and expand the raw JSON entry to see the rest.

## Verifying against a deployed environment

Reaching the deployed API needs **two** headers, and confusing them wastes time:

- `Authorization: Bearer <asgardeo token>` for the Choreo gateway. Its failure
  is the `900901` body above.
- `x-jwt-assertion: <attendee JWT>` for this service. Its failure is
  `{"error":"missing authorization token"}`.

The gateway does **not** derive the second from the first: it validates the
Bearer and forwards `x-jwt-assertion` through untouched
(`.claude/prod-audit/report-E-auth.md:18-19`), so both have to be sent.

`POST /users/profile` is the only AI route that relays the upstream response
verbatim — status, `Content-Type` and body — so when the AI routes misbehave it
is still the one that shows you what the AI service actually said, where every
other route flattens the failure into `500 {"message":"internal error"}`.

With one deliberate exception, and it is the case you are most likely chasing:
a **401 or 403 is intercepted** and answered as a generic 500 like everywhere
else. Those two can only come from the gateway — the AI service authenticates
nobody — and relaying them would both disclose the gateway's error taxonomy and
hand the frontend a 401 on an ordinary call, which its auth interceptor reads as
an expired attendee session and acts on. So a credential problem looks the same
on every route; read it from the **logs**, where the status and a credential
hint are in the message. Everything else, including the AI service's own 4xx,
still passes through untouched.

## Conventions

- External integrations live in `internal/clients/<name>`, each with a
  `NewClient(cfg)` for production and a `NewClientWithHTTPClient` for tests.
- Anything a deployment can get wrong in a way that produces a service which
  boots and then fails every request belongs in `config.Validate()`, as a
  startup error rather than a log line. Feature flags follow this too: a flag
  that is on must mean the feature can actually work.
- `.claude/` is gitignored and holds working notes, audits and credentials.
  Nothing in it belongs in a commit.
