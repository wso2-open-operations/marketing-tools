# How to test One WSO2 locally

How to run the One WSO2 web app on your machine, sign in, point it at a local backend, and add new screens (the Amplify perspective, its rail items and its pages).

Verified on 2026-10-16 against `projects/one-wso2` (fork `BechtelCanDoIt/one-wso2`, `main` at `70a420e1`):

| Check | Result |
| --- | --- |
| `npm ci` with Node 22.23.2 / npm 10.9.8 | 706 packages installed in 12 s |
| `npx tsc -b` | Clean, about 30 s |
| `npm run dev` | Vite 7.2.4 ready on http://localhost:3000. `/` and deep links such as `/me/leave` both return 200 |

I didn't run `npm test` or `npm run lint` for this guide. Run them before any PR (step 6).

---

## 1. What you're running

- A React 19 + TypeScript + Vite single-page app using Oxygen UI (WSO2's MUI-based design system). There's no server of its own.
- **Sign-in is required.** Every route sits behind `<AuthGuard>`, which sends you to Asgardeo. There's no dev bypass, so you need an Asgardeo SPA app (step 3).
- **Backends are optional.** Each feature reads its own URL from `window.config`. When a URL isn't set, that screen shows "This app isn't connected yet. Set `ONE_WSO2_…` in `public/config.js`" and makes no requests. You can run the whole shell with only the auth keys filled in.
- Config is loaded at **runtime** from `public/config.js` (git-ignored). One build serves every environment.

## 2. Prerequisites

- **Node 22** (`webapp/.nvmrc` says `22`; Vite 7 needs at least 20.19). With nvm: `nvm use` in `webapp/`.
- **npm.** The lockfile is `package-lock.json`, so use `npm ci` for a clean install.
- **Git remotes.** `projects/one-wso2` is its own git repo (your fork). Add the upstream once:

```bash
cd projects/one-wso2
git remote add upstream git@github.com:wso2-open-operations/one-wso2.git
git fetch upstream
git switch -c feat/amplify upstream/main      # never work on main
```

## 3. Get an Asgardeo app for localhost

The app asks for the scopes `openid email groups profile` (`src/config/authConfig.ts`). Backends check the **id_token** claims `email` and `groups`.

Local identity is a **non-prod Asgardeo org**, not WSO2 Identity Server, because One WSO2 needs Asgardeo. There's no local IdP container.

**Option A (recommended): use the team's non-prod Asgardeo org.** Ask the One WSO2 owners for the client ID of the existing dev/staging SPA app there, and check that `http://localhost:3000` is in its authorized redirect URLs. You sign in with a non-prod account that has real groups.

**Option B: your own free Asgardeo org,** if you need to control the users and groups yourself.
1. Create an org at asgardeo.io, then go to **Applications → New → Single-Page Application**.
2. **Authorized redirect URL:** `http://localhost:3000`. **Allowed origin:** `http://localhost:3000`. PKCE is on by default for SPAs, so leave it.
3. **User attributes:** add `email`, and make **groups** a requested attribute so it ends up in the id_token.
4. Create a test user. For Amplify, also create the role groups `amplify_po`, `amplify_marketing`, `amplify_slt` and `amplify_admin` (an ordinary employee has none of these), and create one test user per role, so you can test the role-gated screens.

**Option C: ThunderID.** Set `ONE_WSO2_AUTH_WELL_KNOWN_URL` to ThunderID's discovery document as well as the base URL and client id. One WSO2 then signs in through `ThunderProvider` (`src/context/auth/ThunderProvider.tsx`), which hands the SDK that discovery URL; without it the SDK assumes Asgardeo's layout and rejects ThunderID's issuer. The client needs the `groups` scope and `http://localhost:3000` as redirect URL and allowed origin. ThunderID's access token carries no `email`; see [TestAmplify.md](TestAmplify.md) for how the local proxy handles that.

> Port matters. Vite is set to port 3000. If 3000 is busy, Vite picks the next free port, and sign-in then fails with a redirect mismatch. Run `npx vite --port 3000 --strictPort` to fail fast instead.

## 4. Create `public/config.js`

```bash
cd projects/one-wso2/webapp
cp public/config.js.example public/config.js
```

The minimum for a working sign-in:

```js
window.config = {
  ONE_WSO2_AUTH_BASE_URL: "https://api.asgardeo.io/t/<your-org>",
  ONE_WSO2_AUTH_CLIENT_ID: "<spa-client-id>",
  ONE_WSO2_AUTH_SIGN_IN_REDIRECT_URL: "http://localhost:3000",
  ONE_WSO2_AUTH_SIGN_OUT_REDIRECT_URL: "http://localhost:3000",
  ONE_WSO2_THEME: "wso2",

  // Turn on built-but-unreleased features while you work on them.
  ONE_WSO2_PREVIEW_FEATURES: { amplify: true },   // once the `amplify` flag exists (step 8)

  // Feature backends: leave unset to see the "not connected" state.
  // ONE_WSO2_AMPLIFY_BACKEND_URL: "http://localhost:3000/amplify-backend",  // see step 7
};
```

> Don't skip this file. Without it, Vite's single-page fallback answers `/config.js` with `index.html` and a 200. So you won't see a 404, but `window.config` is undefined and sign-in breaks in confusing ways.

Never commit `config.js`. It's already git-ignored.

## 5. Run it

```bash
npm ci
npm run dev          # http://localhost:3000
```

1. Open http://localhost:3000. You're sent to Asgardeo, then back to the **Me** perspective.
2. Deep links work. `AuthGuard` saves the URL you asked for in `sessionStorage.one_wso2_post_login_redirect` and returns you there after sign-in.
3. In dev, an **auth** pill sits at the bottom right of every page. It decodes your id_token and access token. Use it to check that `email` and `groups` are present when a backend rejects you.
4. Switch perspectives with the **waffle** (top right). The left rail shows only the active perspective's sections.
5. Theme and light/dark mode are in the top bar. The live app defaults to the dark navy theme in the wireframes.

## 6. Checks before a PR

```bash
npx tsc -b && npm test && npm run lint
```

Tests are Vitest with Testing Library under jsdom (`src/test/setup.ts`). Use `npm run test:watch` while you work.

## 7. Point it at a local backend (for example `amplify-api`)

amplify-api is a Ballerina service. In Choreo it sits behind the **Choreo API Proxy** at the edge of the Amplify cell, which checks the user's token and passes `x-jwt-assertion` to amplify-api.

**Locally: the dev proxy.** Run the Compose stack from `apps/amplify` (`make up`, amplify-api on :9090), then `node local/one-wso2-proxy/proxy.mjs` (:9089) and set `ONE_WSO2_AMPLIFY_BACKEND_URL: "http://localhost:9089"`. The proxy handles CORS for :3000 and swaps your sign-in token for a local dev JWT carrying the same `sub`, email and groups, which amplify-api accepts only when `ENVIRONMENT=local` (ADR-023). Full walkthrough, including people-stub for photos and team rosters: [TestAmplify.md](TestAmplify.md).

**Closest to production: local WSO2 API Manager** (`make up PROFILE=apim`), with the IdP as key manager, so amplify-api gets a real gateway JWT. Pending the non-prod Asgardeo org; steps in `compose.yaml`.

Things that differ locally:
- **The proxy doesn't verify your token.** It only reads its claims, and amplify-api's dev-JWT mode refuses to run outside `ENVIRONMENT=local`. Never point the proxy at anything but a local stack.
- **The CSP only applies to production builds** (`cspPlugin` uses `apply: "build"`), so `http://localhost` calls work in dev. Before shipping, check that the deployed backend URL fits the CSP (`*.wso2.com`).

## 8. How to add screens

### How the app is organised

```
Perspective (waffle tile, e.g. "Amplify")      constants/perspectives.ts  → PERSPECTIVES
  └─ Rail sections (left menu items)           constants/perspectives.ts or constants/<x>Apps.ts
       └─ Route → Page (the screen)            App.tsx  → features/<x>/pages/*.tsx
            └─ Tabs (each tab is a route)      components/routed-tabs/RoutedTabs
            └─ Dialogs (Oxygen <Dialog>)       inside the page; e.g. finance/masterdata/MasterDataFormDialog
```

Rules from `projects/one-wso2/docs/conventions.md` that every screen follows:
- **Tabs are routes**, and a deep link rebuilds the screen from the URL alone.
- **Gate at the route**, not only in the rail. Rail items for a role are **hidden**, not locked.
- **The gate ladder:** Not configured → Resolving (spinner, no redirects) → Failed (error with Retry) → Denied (say who to ask) → Allowed.
- Server state lives in TanStack Query. Confirm before anything externally visible, such as **Share** to LinkedIn, and disable the button while the request is in flight.

### Recipe: the Amplify perspective

> **Built (2026-10-19).** The phase 1 module now exists on `feat/amplify-people-data`: `features/amplify` (Celebrate, New Post, Current Posts, LinkedIn callback), `components/route-guards/AmplifyEditorRoute.tsx`, the `amplify` preview flag and the trophy app mark. The checklist below is how it was put together, and still the recipe for adding the later-phase screens.

The checklist from the One WSO2 review. File paths are under `webapp/src/`.

1. **Preview flag.** In `config/previewFeatures.ts`, add `| "amplify"` to the `PreviewFeature` union with a doc comment saying what it hides. Delete the entry when Amplify ships.
2. **Config key.** In `config/authConfig.ts`, add `ONE_WSO2_AMPLIFY_BACKEND_URL?: string;` to `interface Window { config … }`. In `config/apiConfig.ts`, copy the TIL pattern:
   ```ts
   export const amplifyBackendUrl: string = (window.config?.ONE_WSO2_AMPLIFY_BACKEND_URL ?? "").replace(/\/+$/, "");
   export function isAmplifyConfigured(): boolean { return Boolean(amplifyBackendUrl); }
   export const amplifyServiceUrls = {
     me: `${amplifyBackendUrl}/me`,
     posts: `${amplifyBackendUrl}/posts`,
     shares: `${amplifyBackendUrl}/shares`,
     checkins: `${amplifyBackendUrl}/checkins`,
     leaderboard: `${amplifyBackendUrl}/leaderboard`,
   };
   ```
   Then add the key, commented, to `public/config.js.example`.
3. **Rail sections.** The Amplify rail is flat (Home, Campaigns, Check-in, New Campaign, Dashboard, PO review, Admin), so use leaf sections like `KNOWLEDGE_BASE_SECTIONS` rather than `appsToSections()`. `appsToSections()` makes collapsible groups, one per app:
   ```ts
   const AMPLIFY_SECTIONS: PerspectiveSection[] = [
     { id: "amplify-home", label: "Home", icon: TrophyIcon, path: "/amplify" },
     { id: "amplify-campaigns", label: "Campaigns", icon: MegaphoneIcon, path: "/amplify/campaigns" },
     { id: "amplify-checkin", label: "Check-in", icon: UploadIcon, path: "/amplify/check-in" },
     { id: "amplify-new-campaign", label: "New Campaign", icon: CirclePlusIcon, path: "/amplify/campaigns/new" },
     { id: "amplify-dashboard", label: "Dashboard", icon: BarChart3, path: "/amplify/dashboard" },
     { id: "amplify-review", label: "PO Review", icon: CoinsIcon, path: "/amplify/review" },
     { id: "amplify-admin", label: "Admin", icon: SlidersHorizontalIcon, path: "/amplify/admin" },
   ];
   ```
   Roles come from amplify-api's `GET /me`, not the app-wide `requires` capabilities. Mark the restricted ids in the Amplify gate (step 6).
4. **Perspective.** Add a flagged entry to `PERSPECTIVES` in `constants/perspectives.ts`, the same way TIL does it:
   ```ts
   ...(isPreviewEnabled("amplify")
     ? [{
         key: "amplify", label: "Amplify", icon: MegaphoneIcon,
         access: true, externallyGated: true, forwardsToFirstItem: true,
         path: "/amplify", sections: AMPLIFY_SECTIONS,
       }]
     : []),
   ```
5. **Routes and pages.** In `App.tsx`, add the routes inside a flagged fragment, gated at the route:
   ```tsx
   {isPreviewEnabled("amplify") && (
     <>
       <Route path="amplify" element={<AmplifyHomePage />} />
       <Route path="amplify/campaigns" element={<CampaignsPage />} />
       <Route path="amplify/check-in" element={<CheckInPage />} />
       <Route path="amplify/campaigns/new" element={<AmplifyRequires role="amplify_marketing"><NewCampaignPage /></AmplifyRequires>} />
       <Route path="amplify/dashboard" element={<AmplifyRequires role={["amplify_po", "amplify_slt"]}><DashboardPage /></AmplifyRequires>} />
       <Route path="amplify/review" element={<AmplifyRequires role="amplify_po"><ReviewPage /></AmplifyRequires>} />
       <Route path="amplify/admin" element={<AmplifyRequires role="amplify_admin"><AdminPage /></AmplifyRequires>} />
     </>
   )}
   ```
   Each page lives in `features/amplify/pages/` and opens with a shell copied from `features/til/components/TilShell.tsx`: an h1 `variant="h5"`, a `body2` subtitle, a primary action on the right, and the "not connected" `Alert` naming `ONE_WSO2_AMPLIFY_BACKEND_URL` when `isAmplifyConfigured()` is false.
6. **Gate.** Write `features/amplify/api/useAmplifyGate.ts` modelled on `features/marketing-ops/api/useMarketingOpsGate.ts`. It wraps `GET /me` with TanStack Query and returns `{ canSee(itemId), isResolving, isError, retry, … }`, with a `RESTRICTED_IDS` set that fails closed. Wire it into `components/side-rail/usePerspectiveVisibility.ts` (keyed on `"amplify"`), and put an `AmplifyRequires` route guard over the restricted routes, following `MarketingOpsShell.tsx`.
7. **Waffle look.** Add a hue in `config/perspectiveHues.ts`. Watch out: `perspectiveHues.test.ts` caps the palette at 9, while the file's comment says 11 are registered, so get a ruling from the One WSO2 owner. Optionally add an app mark in `components/app-marks/` (without one, the tile shows the plain line icon).
8. **Me perspective (other team's code).** The Amplify item after Overview, the Amplify panel on Overview, and **My Connections** on Settings change `constants/meApps.ts`, the Overview page and `features/settings/pages/SettingsPage.tsx`. Keep these in a separate PR so the Me owners can review them on their own.
9. **Tests.** Extend `constants/perspectives.test.ts` (Amplify appears only with the flag on) and add tests for the gate and the restricted routes.
10. **Turn it on locally:** `ONE_WSO2_PREVIEW_FEATURES: { amplify: true }` in `config.js`, then reload. Amplify appears in the waffle.

### Dialogs, the other kind of "window"

Copy `features/finance/masterdata/MasterDataFormDialog` (Oxygen `Dialog`, `maxWidth="sm"`, `fullWidth`, dividers, an actions row) for things like the **Share / repost with thoughts** dialog, the PO **adjust points** dialog, and the **check-in** form. For confirmation, use `components/confirmation-dialog`, and for toasts, `useNotifications()` from `context/notifications`.

## 9. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Sign-in loops, or "redirect_uri mismatch" | `ONE_WSO2_AUTH_SIGN_IN_REDIRECT_URL`, the Asgardeo app's redirect URL and the port you're on don't all match (step 3, the port note) |
| A blank shell or odd auth errors | `public/config.js` is missing (Vite answers with `index.html` instead) |
| "This app isn't connected yet" | That feature's backend key isn't set. Expected when you run with auth only |
| Backend returns 401/403 locally | You're using a shortcut without APIM, so the backend gets `Authorization: Bearer` rather than `x-jwt-assertion`. Or the user isn't in the `amplify_*` group. Check the claims with the **auth** pill |
| A new perspective doesn't show | The preview flag is off in `config.js`, or the gate hides every item |
| `tsc` errors after pulling | Rebase on `upstream/main`, then run `npm ci` again |
