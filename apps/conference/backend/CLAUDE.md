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
calling an Organization one, unchanged in production. Copy its shape.

1. **Point at the internal gateway URL**, version suffix included:
   `https://<org>-<env>-internal.prod-internal.wdt.choreoapis.dev/<project>/<component>/v1.0`.
   There is no in-cluster address to use instead — `svc.cluster.local` appears
   nowhere in the reference, and the internal gateway host does not resolve off
   the dataplane, so it cannot be probed from a laptop.
2. **Send `Authorization: Bearer <token>`** from an OAuth2 `client_credentials`
   grant against Asgardeo (`https://api.asgardeo.io/t/wso2/oauth2/token`), with
   the client id and secret presented as HTTP Basic. In this repo that means a
   `config.OAuthClientConfig` plus `clientcredentials.Config` with
   `AuthStyle: oauth2.AuthStyleInHeader`, exactly as `clients/wallet`,
   `clients/qrportal` and `clients/transaction` already do.
3. **Subscribe the OAuth2 application to the callee's API** in the Choreo
   console. A valid id and secret that is not subscribed still yields `900901`.
4. **Keep any caller-identity header separate.** `x-jwt-assertion` carries the
   attendee's own JWT and answers "who is asking"; the Bearer token answers "may
   this service call at all". They are not interchangeable and dropping either
   breaks a different thing.

### Reading the failures

Both gateways in the path emit a byte-identical
`401 {"error_message":"Invalid Credentials","code":"900901",...}` body, so the
body cannot tell you which one rejected you. The **headers** can:

| Rejected by | Tell |
|---|---|
| This service's own front gateway (your Bearer is bad) | `www-authenticate: Bearer realm="Choreo Connect"` and `x-trace-key`; **no** `x-envoy-upstream-service-time` |
| A gateway further upstream, relayed through this service | `x-envoy-upstream-service-time` and `x-ratelimit-*`; **no** `www-authenticate` |

Other gateway codes worth recognising: `900906` is "no matching resource" — the
path is absent from the callee's published OpenAPI spec, since a Choreo managed
API only proxies paths its spec declares. `900912` is a credential minted for
the wrong environment (sandbox key against production, or the reverse).

Latency is a second tell. An AI route that fails in single-digit milliseconds
never reached a model; it was refused at a gateway.

### Logs

`APP_ENV=production` selects `slog.NewJSONHandler` (`cmd/server/main.go`), and
the Choreo log viewer's summary line renders only slog's **message**, dropping
its attributes. An upstream status put in an attribute is therefore invisible
where people actually look. Put anything needed for diagnosis in the message
itself — `handlers.respondAIUpstreamError` does this deliberately — and expand
the raw JSON entry to see the rest.

## Verifying against a deployed environment

Reaching the deployed API needs **two** headers, and confusing them wastes time:

- `Authorization: Bearer <asgardeo token>` for the Choreo gateway. Its failure
  is the `900901` body above.
- `x-jwt-assertion: <attendee JWT>` for this service. Its failure is
  `{"error":"missing authorization token"}`.

The staging gateway does **not** derive the second from the first, and its CORS
preflight does not allow `x-jwt-assertion`, so sending it by hand works from
curl but is blocked in a browser.

`POST /users/profile` is the only AI route that relays the upstream response
verbatim — status, `Content-Type` and body. When the AI routes misbehave, call
it first: every other route flattens the upstream failure into
`500 {"message":"internal error"}`.

## Conventions

- External integrations live in `internal/clients/<name>`, each with a
  `NewClient(cfg)` for production and a `NewClientWithHTTPClient` for tests.
- Anything a deployment can get wrong in a way that produces a service which
  boots and then fails every request belongs in `config.Validate()`, as a
  startup error rather than a log line. Feature flags follow this too: a flag
  that is on must mean the feature can actually work.
- `.claude/` is gitignored and holds working notes, audits and credentials.
  Nothing in it belongs in a commit.
