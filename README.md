# SnapCal AI

Photo → calories in seconds. SwiftUI (iOS 18+) client, Fastify + PostgreSQL API.

```
iPhone ──HTTPS──▶ Railway API ──▶ PostgreSQL
                       └────────▶ OpenAI / Gemini
                       └────────▶ USDA FDC · Open Food Facts
```

No Redis: nothing in the app needs a second datastore. The two things caching
would serve — repeat-image analysis and nutrition lookups — are already handled
by the `analysis_cache` and `food_database` tables, and rate limiting is
in-process because the API runs as a single Railway service. Adding Redis would
be infrastructure without a job.

The iOS app talks only to our API. It contains no provider keys, no database
credentials and no JWT secret.

---

## Repository layout

```
snapcal/
├── ios/
│   ├── SnapCal.xcodeproj/          committed; opens directly in Xcode 16+
│   ├── SnapCal/                    app sources, assets, Info.plist, entitlements
│   ├── SnapCalTests/               unit tests (Swift Testing)
│   ├── SnapCalUITests/             launch smoke test
│   ├── Config/                     Base/Debug/Release xcconfig + StoreKit test file
│   └── tools/                      project generator + validator
├── backend/
│   ├── src/                        Fastify API
│   ├── migrations/                 forward-only SQL
│   ├── test/e2e.mjs                integration suite
│   ├── Dockerfile
│   └── railway.json
├── codemagic.yaml
├── .env.example
└── .gitignore
```

---

## Local development

### Backend

```bash
cd backend
cp ../.env.example .env          # then fill in JWT_SECRET at minimum
npm ci
npm run build
npm run migrate                  # creates schema + seeds regional foods
npm run dev                      # http://localhost:8080
```

No OpenAI key? `AI_PROVIDER=mock npm run dev` returns a deterministic Indian
thali and spends nothing.

Verify:

```bash
curl localhost:8080/health
# {"ok":true,"provider":"mock","model":"gpt-5.6-luna","version":"dev"}
```

### Integration tests

Needs a running API and a reachable database:

```bash
cd backend
DATABASE_URL=postgres://postgres@127.0.0.1:5432/snapcal \
JWT_SECRET=$(openssl rand -base64 48) \
AI_PROVIDER=mock node dist/server.js &

DATABASE_URL=postgres://postgres@127.0.0.1:5432/snapcal \
JWT_SECRET=<same value> \
API=http://localhost:8080 \
node --test test/e2e.mjs
```

Covers auth, target calculation, the concurrent scan-quota race, food
resolution, meal maths, dashboard aggregation, escalation cost accounting and
account deletion.

### iOS

```bash
open ios/SnapCal.xcodeproj
```

Debug builds point at `http://localhost:8080/api/v1` (see `Config/Debug.xcconfig`).
For StoreKit testing: Product → Scheme → Edit Scheme → Run → Options →
StoreKit Configuration → `Config/SnapCal.storekit`.

After adding or removing Swift files:

```bash
python3 ios/tools/generate_xcodeproj.py
python3 ios/tools/validate_xcodeproj.py
```

---

## Deployment

### Step 1 — GitHub

```bash
git init && git add . && git commit -m "SnapCal"
gh repo create snapcal --private --source=. --push
```

`.gitignore` excludes `.env`, `*.p8`, `*.p12`, `*.mobileprovision` and
certificates. The `.xcodeproj` **is** committed — only `xcuserdata/` is ignored.

### Step 2 — Railway backend

New Project → Deploy from GitHub → select the repo.
Add **PostgreSQL** from the Railway dashboard; `DATABASE_URL` is injected
automatically.

Set the service root directory to `backend` (Settings → Source → Root Directory)
so Railway uses `backend/Dockerfile`.

### Step 3 — Railway environment variables

Required:

| Variable | Value |
|---|---|
| `DATABASE_URL` | injected by the PostgreSQL plugin |
| `JWT_SECRET` | `openssl rand -base64 48` |
| `OPENAI_API_KEY` | your key — server side only |
| `NODE_ENV` | `production` |

Optional but recommended: `USDA_FDC_API_KEY` (free), `GEMINI_API_KEY` (enables
failover), `ADMIN_USER_IDS` (unlocks `/api/v1/admin/cost`).
Full list in `.env.example`.

### Step 4 — Migrations

They run automatically at boot behind a Postgres advisory lock, so multiple
replicas are safe. To run them manually instead, set
`RUN_MIGRATIONS_ON_BOOT=false` and use a Railway one-off command:

```bash
npm run migrate
```

Migrations are forward-only and additive — no migration drops or truncates
anything. Editing an already-applied file is rejected by checksum; add a new
numbered file instead.

Confirm:

```bash
curl https://<your-railway-domain>/health
```

### Step 5 — Point the app at production

Edit `ios/Config/Release.xcconfig`:

```
API_HOST = api.snapcal.app          # or snapcal-api.up.railway.app
```

Nothing in Swift changes; the URL flows through Info.plist. The Codemagic
pipeline refuses to build if this still says `localhost` or is not HTTPS.

### Step 6 — Apple Developer / App Store Connect

1. App ID `app.snapcal.ios` with **Sign in with Apple** enabled
2. App Store Connect → new app, bundle ID `app.snapcal.ios`
3. Subscription group **SnapCal Pro** with:
   - `app.snapcal.pro.monthly` — $6.99/month
   - `app.snapcal.pro.yearly` — $39.99/year
4. Sign the Paid Applications agreement and complete banking/tax, or the
   products stay in *Missing Metadata* and the paywall renders empty
5. Users → Keys → **App Store Connect API Key** (App Manager role). Download the
   `.p8` once and note the Issuer ID and Key ID

### Step 7 — Codemagic

Connect the GitHub repo. Under Teams → Integrations → Developer Portal, add the
App Store Connect API key. Then create two variable groups:

**`app_store_credentials`**
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_IDENTIFIER`
- `APP_STORE_CONNECT_PRIVATE_KEY` — paste the whole `.p8` contents, mark secure

**`certificate_credentials`**
- `CERTIFICATE_PRIVATE_KEY` — only if you are not using Codemagic-managed signing

Plus `APP_STORE_APPLE_ID` (the numeric app ID) and `NOTIFY_EMAIL`.

Signing is automatic: `app-store-connect fetch-signing-files --create` issues the
distribution certificate and provisioning profile at build time. No certificate
or profile is ever committed.

### Step 8 — Build

Push to `main`. The `ios-testflight` workflow validates the project, refuses
non-HTTPS or localhost API hosts, checks `/health` on the live backend, bumps
the build number past the latest TestFlight build, runs tests, archives in
Release and exports the IPA.

### Step 9 — TestFlight

The pipeline uploads and assigns to the *Internal Testers* group. Internal
testers get it in minutes with no review. External testers need a Beta App
Review pass, normally about a day.

### Step 10 — End-to-end test on device

Sign in with Apple → complete onboarding → scan a real plate → confirm the
macros → check the diary and dashboard → open the paywall → purchase in the
sandbox → restore purchases → delete the account.

---

## App Store review checklist

Already handled in the repo:

- Camera, photo library, microphone and speech usage strings that name the
  feature and say what happens to the data
- Sign in with Apple entitlement wired to the target
- Account deletion (`DELETE /api/v1/account`, cascades every row) — required
  because the app creates accounts
- Data export (`GET /api/v1/account/export`)
- Restore Purchases on the paywall; subscription terms and renewal disclosure
- Estimate disclaimers on the confirm screen, settings and every API response

Still yours to provide:

- Working privacy policy and terms URLs (currently `snapcal.app/privacy` and
  `/terms` — placeholders that must resolve before review)
- App Store privacy nutrition labels declaring health/fitness data collection
- `PrivacyInfo.xcprivacy` if you add SDKs that require declared API reasons

The app makes no medical claims. Every nutrition figure is labelled an estimate
in the UI and in the API payload; keep it that way.

## Cost

Verified pricing at 13 Aug 2026 and the reasoning behind the provider choice
are in `ARCHITECTURE.md`. Roughly $0.00031 per scan on GPT-5.6 Luna, about
$312 per million scans. The live ledger is at `/api/v1/admin/cost`.
