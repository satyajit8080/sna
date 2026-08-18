# Getting BP Coach onto TestFlight

The CI workflow (`bp-coach`) builds for the **simulator, unsigned**. It proves
the code compiles and the tests pass, and it deliberately produces no `.ipa` —
which is why a green build never appeared in TestFlight.

Distribution is a second workflow (`release`) that signs, archives and uploads.
It needs things CI does not: a paid Apple Developer account, an App Store
Connect API key, and a registered bundle identifier.

---

## 1. Bundle identifier — already decided

BP Coach ships as **an update to SnapCal**, under `app.snapcal.ios`. SnapCal is
retired and its users migrate to the new product.

This is already set in `project.yml` and `codemagic.yaml`. Do not change it: a
different identifier would create a separate app and leave the existing users on
a dead one.

### What comes with that decision

| | |
|---|---|
| ✅ App ID exists, HealthKit already enabled | no portal work needed |
| ✅ App Store Connect record exists | no new app to create |
| ✅ CodeMagic and Railway already wired to this repo | |
| ⚠️ Existing users **auto-update** into a blood pressure app | their calorie data is unreachable — different store, different schema |
| ⚠️ Reviews and ratings carry over | they cannot be removed |
| ⚠️ Metadata must be fully rewritten | name, subtitle, description, keywords, screenshots |
| ⚠️ Privacy nutrition label must be rewritten | health data is a scrutinised category |
| ⚠️ Any active SnapCal subscriptions still bill | for a product that no longer exists |

### Version numbering

SnapCal's last `MARKETING_VERSION` was `1.0.0`. `project.yml` is set to `2.0.0`
— a major bump, which is honest for a wholesale product change and clears the
"version must be higher" rejection.

### Before the first upload

- [ ] Confirm no SnapCal auto-renewing subscriptions are active. If any are,
      stop new signups and plan refunds — charging for a retired product invites
      complaints and Apple intervention.
- [ ] Rewrite the App Store listing to describe BP Coach. Shipping a blood
      pressure app under calorie-tracker metadata is a Guideline 2.3 rejection.
- [ ] Update the privacy nutrition label for health data.
- [ ] Consider a release note that says plainly what happened, so existing users
      are not simply confused.

---

## 2. Create an App Store Connect API key

App Store Connect → **Users and Access** → **Integrations** → **App Store
Connect API** → **+**.

- Access: **App Manager**
- Download the `.p8` **immediately** — it is offered once and never again
- Note the **Issuer ID** and the **Key ID**

---

## 3. Connect it to CodeMagic

CodeMagic → **Teams** → **Integrations** → **Developer Portal** → **Add key**.

- Name it exactly **`BPCoachASC`** — `codemagic.yaml` references it by name
- Paste the Issuer ID, Key ID, and the contents of the `.p8`

Then in the app's **Environment variables**, add to the `release` workflow:

```
BPCOACH_API_BASE_URL = https://<your-domain>.up.railway.app
```

Leave it out and the app still ships — the coach and food search report
themselves unavailable, and R2 prints a warning rather than failing.

---

## 4. Run it

The `release` workflow triggers on tags matching `v*`:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Or start it manually in CodeMagic and pick the `release` workflow.

### What it does

| Stage | Purpose |
|---|---|
| R0 | Security sweep — same gate as CI |
| R1 | Generate the Xcode project from `project.yml` |
| R2 | Resolve and validate the backend URL |
| R3 | Read the latest TestFlight build number and increment it |
| R4 | Fetch signing files, create them if absent |
| R5 | Archive and export a signed `.ipa` |
| R6 | Inspect the IPA before it leaves the machine |
| — | Upload to TestFlight |

**R3 matters.** TestFlight rejects a build number it has already seen. The
number is derived from what is actually on TestFlight rather than from the `1`
committed in `project.yml`, so repeated uploads do not collide.

**R6 checks four things** inside the built IPA rather than trusting the build:
the bundle identifier, that the backend URL actually reached `Info.plist`, that
`NSHealthShareUsageDescription` is present (App Review rejects a HealthKit app
without it), and that no design-reference PNG was shipped.

---

## 5. After the upload

The build appears in App Store Connect → your app → **TestFlight** within about
5–15 minutes while Apple processes it.

- **Internal testers** (up to 100, on your team) can install immediately
- **External testers** require **Beta App Review**, usually a day or two

You will be asked for **export compliance**. BP Coach uses HTTPS only and no
custom cryptography, so the standard exemption applies — but confirm that
against your own legal position rather than taking it from here.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "No matching profiles found" | See the dedicated section below — usually the API key role, or the App ID not being on this team |
| "The bundle version must be higher than the previously uploaded version" | `MARKETING_VERSION` is at or below SnapCal's `1.0.0` |
| "App name is already in use" | Renaming the App Store record — do it in App Store Connect, not in the build |
| "Invalid Bundle. Missing entitlement" | HealthKit not enabled on the App ID |
| "The bundle version must be higher" | R3 could not read the latest build number — check the API key has App Manager access |
| Upload succeeds, nothing in TestFlight | Still processing, or the build was rejected by email — check the address on your Apple ID |
| "Missing purpose string" | `NSHealthShareUsageDescription` absent — R6 catches this before upload |
| Build fails at R4 | The integration name in CodeMagic is not exactly `BPCoachASC` |

---

## "Cannot save Signing Certificates without certificate private key"

A signing certificate is a public certificate **plus a private key**. Apple
issues the certificate; the private key is yours and Apple never sees it. So
`--create` can request a certificate but cannot conjure the key to go with it.

You generate that key once and store it in CodeMagic. Reusing the same key every
build matters: a new key means a new certificate, and Apple allows only two or
three distribution certificates per account before refusing to issue more.

### Generate the key

**Windows (PowerShell)** — omit `-N` and press Enter twice at the prompts:

```powershell
ssh-keygen -t rsa -b 2048 -m PEM -f bpcoach_cert.key
notepad bpcoach_cert.key
```

> Do **not** use `-N '""'` on PowerShell. It sets the passphrase to a literal
> two-quote string rather than an empty one, producing an encrypted key. The
> CLI then reports "Not a valid certificate private key", which does not hint
> at the real cause.

**macOS or Linux:**

```bash
ssh-keygen -t rsa -b 2048 -m PEM -f bpcoach_cert.key -q -N ""
cat bpcoach_cert.key
```

Either way, the first line must read exactly:

```
-----BEGIN RSA PRIVATE KEY-----
```

If it says `ENCRYPTED` or `OPENSSH`, it is wrong — delete both files and start
again.

Copy the **entire** file, including the `-----BEGIN RSA PRIVATE KEY-----` and
`-----END RSA PRIVATE KEY-----` lines.

Ignore the `.pub` file it also writes — only the private key is needed.

### Store it in CodeMagic

App settings → **Environment variables**:

| Field | Value |
|---|---|
| Variable name | `CERTIFICATE_PRIVATE_KEY` |
| Value | the whole PEM key, including both header lines |
| Group | leave blank, or match a group already in the workflow |
| **Secure** | ✅ **tick this** |

Ticking Secure means the value is encrypted and never printed in a log. An
unticked private key ends up in plain text in your build output.

### Keep the file

Store `bpcoach_cert.key` in a password manager. Losing it means the next build
issues a new certificate, and at Apple's limit you would have to revoke an
existing one — which invalidates every profile depending on it.

---

## "No matching profiles found"

The most common failure, and it has four distinct causes. Stage **R3b** prints
what the API key can actually see, which tells you which one you have.

### 1. The API key role is too low

`--create` has to make a signing certificate if none exists, and **App Manager
cannot create certificates — only Admin can.** This is the usual cause.

Fix: App Store Connect → Users and Access → Integrations → your key. If it is
App Manager, create a new key with **Admin** and update the CodeMagic
integration.

### 2. No distribution certificate exists

If R3b's certificate list is empty and the key is only App Manager, nothing can
create one. Either raise the role, or create an **Apple Distribution**
certificate manually in the Developer portal.

Note the account limit of two distribution certificates. If you are at the
limit, revoke an unused one first.

### 3. The App ID is not registered, or is on a different team

If R3b's bundle ID list is empty, `app.snapcal.ios` is not visible to this key.

- Confirm it exists: developer.apple.com → Identifiers
- Confirm the key belongs to the **same team** that owns SnapCal. A personal
  team key cannot see an organisation's App IDs.

### 4. The identifier does not match

`project.yml` and `codemagic.yaml` must agree exactly, and both must match the
registered App ID. A trailing space or a `.tests` suffix in the wrong place is
enough.

```bash
grep -n "app.snapcal.ios" project.yml codemagic.yaml
```

### Fallback: create the profile by hand

If R4 still fails, make it manually and let CodeMagic use it:

1. Developer portal → Profiles → **+** → **App Store** → select `app.snapcal.ios`
2. Choose your distribution certificate, name it, download it
3. CodeMagic → Teams → **Code signing identities** → upload the `.mobileprovision`
   and the `.p12`
4. Replace R4 with just `keychain initialize && keychain add-certificates && xcode-project use-profiles`

Slower to maintain, but it removes the API key from the signing path entirely.

---

## What this does not cover

TestFlight is not App Store submission. Before public release you still need
screenshots, a description, keywords, a support URL, a privacy policy URL, and
the **privacy nutrition label** — which for a health app is scrutinised closely.
That is the App Store readiness pass, and it has not been done.
