# Phase 0 — New Project, Build Verification, SnapCal Audit

**Status:** IN PROGRESS — documentation scaffolding only.
**Nothing has been built, run, or verified.**

Sections marked 🖥 must be performed on macOS with Xcode. Sections marked 📄 are complete.

---

## Deliverables

| File | Status |
|---|---|
| `CLAUDE.md` | 📄 scaffolded, verification table empty |
| `docs/IMPLEMENTATION_LOG.md` | 📄 scaffolded |
| `docs/SNAPCAL_AUDIT.md` | 📄 structure complete, records empty |
| `docs/DELETION_CANDIDATES.md` | 📄 structure complete, rows empty |
| `docs/phases/PHASE_00.md` | 📄 this file |

---

# ⚙️ EVIDENCE STRATEGY — CodeMagic CI

There is **no local Mac** on this project. All macOS/Xcode verification runs on CodeMagic.

`codemagic.yaml` at the repository root defines the `phase0-evidence` workflow. It never
fabricates a result: every stage prints raw command output or exits with an explicit
BLOCKED marker.

| Stage | Gates covered | Needs `BPCoach.xcodeproj`? |
|---|---|---|
| A1–A5 | Xcode, Swift, SDK, simulators, Git state | **No** |
| B1–B3 | Project, scheme, destination discovery | Yes |
| C1–C4 | Build, tests, deployment target, PNG bundle | Yes |
| D1 | iOS 17.0 API availability probe | No — standalone `swiftc -parse` |

**Stage A can be run today** against a repository containing only the docs. That alone
clears five gates.

## Project generation — DECIDED

**Owner approved Option 2: XcodeGen on CodeMagic.** No physical Mac required.

| Decision | Value |
|---|---|
| Source of truth | `project.yml` |
| `.xcodeproj` | **Generated in CI, never committed** — `.gitignore` excludes `*.xcodeproj/` |
| Hand-editing `.pbxproj` | **Forbidden.** Edit `project.yml` and regenerate. |
| XcodeGen role | Build-time tool only. **Not a runtime or app dependency.** |
| Version pinning | `XCODEGEN_VERSION` in `codemagic.yaml` — currently empty. Read the real version from run A6, then pin it. |

Generating rather than committing is the simpler reproducible option: there is no second
artifact that can drift from the spec, and every CI run proves `project.yml` still works.

### What the scaffolding project contains

| File | Purpose |
|---|---|
| `project.yml` | Target, scheme, iOS 17.0, HealthKit entitlement, usage strings |
| `Sources/BPCoachApp.swift` | `@main` entry point; constructs a SwiftData `ModelContainer` |
| `Sources/ScaffoldView.swift` | One screen that says "Phase 0 scaffolding" |
| `Tests/ScaffoldTests.swift` | Swift Testing; in-memory SwiftData container test |
| `Probes/DeploymentTargetProbe.swift` | iOS 17.0 API availability, original code |

`ScaffoldMarker` is a placeholder persistence model carrying no health data and no clinical
meaning. It is deleted when the real schema lands in Phase 2.

**Deliberately absent:** navigation, tabs, onboarding, BP models, HealthKit reads,
networking, AI, medications, notifications, analytics, subscription. Adding any of those
here would be Phase 1 work.

## Superseded — the borrowed-Mac problem

CodeMagic builds a repository; it cannot create an Xcode project that has never existed.
Stage B1 detects this and **fails the build with an explicit BLOCKED message** rather than
proceeding. Three ways forward — owner decision required:

| Option | How | Cost |
|---|---|---|
| **1. Borrowed Mac, once** | Anyone with Xcode creates the project, commits it. Ten minutes, then CI owns everything after. | Needs Mac access once |
| **2. XcodeGen on CI** | Commit a `project.yml`; CI runs `brew install xcodegen && xcodegen generate` before building. Fully reproducible, no Mac ever needed. | Adds a **build-time** third-party tool — requires owner approval under the no-dependency rule |
| **3. Hand-authored pbxproj** | Write the project file directly. | **Not recommended.** The Master Prompt forbids it, and SnapCal itself needed a Python generator plus a validator to keep one honest. |

Option 1 is cleanest if any Mac is reachable. Option 2 is the right answer if none is.

## How to run

1. Create the GitHub repository, branch `bp-coach`
2. Commit everything: docs, `project.yml`, `codemagic.yaml`, `.gitignore`,
   `Sources/`, `Tests/`, `Probes/`, `design-reference/`
3. Connect the repository in CodeMagic
4. Set `NOTIFY_EMAIL`
5. Push to `bp-coach`
6. Paste the full build log back

All eleven gates run in one pass. Nothing may be marked PASS before that log exists.

---

# 🖥 COMMAND REFERENCE

The commands CodeMagic runs, for reference. Do not run these locally — there is no local Mac.

Run in order. Paste **real output** into `CLAUDE.md` — never a reconstruction from memory.
Anywhere a placeholder appears in `<ANGLE_BRACKETS>`, substitute the value you actually
observed in the preceding step.

---

## Step 1 — Capture the environment

```bash
xcodebuild -version
swift --version
xcrun xcodebuild -showsdks | grep -i iphoneos
xcrun simctl list devices available | grep -i iphone
```

Record in `CLAUDE.md`: Xcode version, Swift version, iOS SDK version, and the exact
simulator names and OS versions available.

Swift Testing ships with Xcode 16 and later. Note the Xcode version now; Step 5 confirms
availability by compilation rather than by assumption.

- [ ] Output pasted into `CLAUDE.md`

---

## Step 2 — Create the project (GUI, not scripted)

Do not generate an `.xcodeproj` by hand or by script.

Xcode → File → New → Project → iOS → App

| Field | Value |
|---|---|
| Product Name | `BPCoach` |
| Team | your team |
| Organization Identifier | `<YOUR_REVERSE_DNS_PREFIX>` |
| Interface | SwiftUI |
| Language | Swift |
| Storage | **None** |
| Testing System | Swift Testing with XCTest UI Tests (if offered) |
| Include Tests | ✅ |
| Host in CloudKit | ❌ |

Then: target → General → Minimum Deployments → iOS **17.0**.

Storage is deliberately **None**. SwiftData vs Core Data is decided after the SnapCal
HealthKit wrapper audit (record A5).

- [ ] Project created
- [ ] Bundle identifier is new and does **not** reuse SnapCal's
- [ ] Deployment target set to 17.0

---

## Step 3 — Initialise the repository

```bash
cd <PATH_TO_BPCOACH_PROJECT_ROOT>

git init
curl -sL https://www.toptal.com/developers/gitignore/api/swift,xcode,macos -o .gitignore
# If you prefer not to fetch, write .gitignore manually — do not skip it.

git checkout -b bp-coach
git status
```

Confirm no SnapCal linkage:

```bash
git remote -v                    # expect: empty
cat .gitmodules 2>/dev/null      # expect: no such file
```

- [ ] `.gitignore` present
- [ ] On branch `bp-coach`
- [ ] No remotes, no submodules

---

## Step 4 — Add the scaffolding and design references

```bash
mkdir -p docs/phases design-reference

# copy in: CLAUDE.md, docs/IMPLEMENTATION_LOG.md, docs/SNAPCAL_AUDIT.md,
#          docs/DELETION_CANDIDATES.md, docs/phases/PHASE_00.md
# copy in: design-reference/part-1.png, design-reference/part-2.png

ls -R docs design-reference
```

In Xcode, confirm the PNGs are **not** in the target:
Target → Build Phases → Copy Bundle Resources → neither PNG may appear.

- [ ] Five docs present
- [ ] Both PNGs in `design-reference/`
- [ ] PNGs absent from Copy Bundle Resources

---

## Step 5 — Discover the scheme and destination

```bash
xcodebuild -list -project BPCoach.xcodeproj
```

Copy the scheme name **exactly** as printed. Then pick a simulator from Step 1 and read
its real OS version:

```bash
xcrun simctl list devices available
```

- [ ] Exact scheme name recorded
- [ ] Exact simulator name and OS version recorded

---

## Step 6 — Verify the build

```bash
xcodebuild build \
  -project BPCoach.xcodeproj \
  -scheme "<EXACT_SCHEME>" \
  -destination "platform=iOS Simulator,name=<EXACT_SIMULATOR>,OS=<EXACT_OS>" \
  | tail -20
```

Expect `** BUILD SUCCEEDED **`.

- [ ] Build succeeds
- [ ] Full command pasted into `CLAUDE.md` and marked ✅

---

## Step 7 — Verify the test run and the testing framework

Add a single trivial test to confirm Swift Testing compiles:

```swift
import Testing

@Test func scaffoldingCompiles() {
    #expect(true)
}
```

If `import Testing` fails to compile, fall back to XCTest and record that choice.

```bash
xcodebuild test \
  -project BPCoach.xcodeproj \
  -scheme "<EXACT_SCHEME>" \
  -destination "platform=iOS Simulator,name=<EXACT_SIMULATOR>,OS=<EXACT_OS>" \
  | tail -30
```

Expect `** TEST SUCCEEDED **`.

- [ ] Tests run and pass
- [ ] Framework choice (Swift Testing or XCTest) recorded in `CLAUDE.md`
- [ ] Full command pasted into `CLAUDE.md` and marked ✅

---

## Step 8 — Confirm the PNGs are not shipped

```bash
APP_PATH=$(xcodebuild -project BPCoach.xcodeproj \
  -scheme "<EXACT_SCHEME>" \
  -destination "platform=iOS Simulator,name=<EXACT_SIMULATOR>,OS=<EXACT_OS>" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR/ {print $2}' | head -1)

ls "$APP_PATH"
find "$APP_PATH" -name 'part-*.png'    # expect: no output
```

- [ ] No design-reference PNG inside the built `.app`

---

## Step 9 — SnapCal audit (read-only)

Pin the commit first. Every path recorded in the audit refers to this SHA.

```bash
SNAPCAL=<PATH_TO_SNAPCAL_REPO>

git -C "$SNAPCAL" rev-parse HEAD
git -C "$SNAPCAL" log -1 --format='%H %cd %s'
git -C "$SNAPCAL" status --porcelain     # expect clean; audit a dirty tree at your peril
```

Survey the source:

```bash
find "$SNAPCAL" -name '*.swift' | wc -l
find "$SNAPCAL" -type d -name '.git' -prune -o -type d -print | head -60
```

Identify third-party dependencies:

```bash
cat "$SNAPCAL"/*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null
cat "$SNAPCAL"/Podfile.lock 2>/dev/null
cat "$SNAPCAL"/Cartfile.resolved 2>/dev/null
```

Locate the audit targets:

```bash
grep -ril 'healthkit'       "$SNAPCAL" --include='*.swift' | head -30
grep -ril 'sodium'          "$SNAPCAL" --include='*.swift' | head -30
grep -ril 'urlsession\|apiclient\|networkservice' "$SNAPCAL" --include='*.swift' | head -30
find "$SNAPCAL" \( -name '*.json' -o -name '*.csv' -o -name '*.sqlite' \) -size +100k
```

For each candidate, check coupling before deciding COPY or ADAPT:

```bash
grep -n '^import\|SnapCal' <CANDIDATE_FILE>
```

Fill in `docs/SNAPCAL_AUDIT.md` — every field, no blanks — and populate the discovered
rows in `docs/DELETION_CANDIDATES.md`.

- [ ] Commit SHA pinned in both documents
- [ ] All six audit records complete
- [ ] Deletion rows populated
- [ ] Owner sign-off recorded
- [ ] **Zero files copied from SnapCal** — Phase 0 is audit only

---

## Step 10 — Close the phase

Update `CLAUDE.md`: flip each ❌ to ✅ with the real value; resolve the persistence
decision if record A5 permits it.

Update `docs/IMPLEMENTATION_LOG.md`: what shipped, what was deferred, what was assumed,
what limitations remain.

```bash
git add -A
git commit -m "Phase 0: new project, build verification, SnapCal audit"
git log --oneline -1
git branch --show-current      # expect: bp-coach
```

---

# Evidence ledger — 2026-08-17

| # | Item | Evidence | Status |
|---|---|---|---|
| 1 | New `BPCoach` Xcode project | none | ❌ macOS required |
| 2 | Verified build command | none | ❌ macOS required |
| 3 | Verified test command | none | ❌ macOS required |
| 4 | Simulator destination | none | ❌ macOS required |
| 5 | iOS 17.0 compile verification of adapted `HealthService` | none | ❌ macOS required |
| 6 | SnapCal HEAD SHA | `db7c6281aee65c742826a446215c2c813011e109`, tree clean | ✅ |
| 7 | SnapCal audit complete | `SNAPCAL_AUDIT.md`, records A1–A6 populated from real inspection | ✅ |
| 8 | Deletion candidates complete | `DELETION_CANDIDATES.md`, D1–D22 + sever-at-copy list | ✅ |
| 9 | Salvage decisions recorded | `CLAUDE.md` decision 1 | ✅ |
| 10 | Sodium finding recorded | `CLAUDE.md` carried-forward requirements; audit A2 | ✅ |
| 11 | HealthKit server-transmission finding recorded | `CLAUDE.md` decision 7; audit A5; deletion §2 | ✅ |
| 12 | SwiftData decision recorded | `CLAUDE.md` decision 3 | ✅ |
| 13 | Deployment-target decision recorded | `CLAUDE.md` decision 2 | ✅ |
| 14 | Font decision recorded | `CLAUDE.md` decision 4 | ✅ |
| 15 | No SnapCal code copied | `find` returns 0 `.swift`/`.xcodeproj`; `grep -ril snapcal` outside docs returns 0 | ✅ |
| 16 | No Phase 1 implementation started | repository contains 5 markdown files and nothing else | ✅ |
| 17 | Design PNGs committed and unbundled | none | ❌ macOS required |
| 18 | Phase 0 commit on `bp-coach` | none | ❌ macOS required |

**Verified: 11 of 18. Six items require macOS with Xcode; one requires a compile.**

---

# Definition of done

Phase 0 is COMPLETE only when every line below is true. Anything short of this is
Phase 0 IN PROGRESS — report it as such.

- [ ] New `BPCoach` Xcode project created
- [ ] Build command verified, real output recorded
- [ ] Test command verified, real output recorded
- [ ] Simulator destination verified, exact name and OS recorded
- [ ] SnapCal HEAD SHA recorded in both audit documents
- [ ] SnapCal audit complete — all nine fields on every record, no blanks
- [ ] Deletion candidates complete — all six fields on every discovered row
- [ ] No SnapCal dependency: no remote, no submodule, no copied file
- [ ] Design-reference PNGs confirmed absent from the built `.app`
- [ ] `CLAUDE.md` updated — every ❌ resolved to ✅ with a real value
- [ ] `IMPLEMENTATION_LOG.md` updated
- [ ] Committed as `Phase 0: new project, build verification, SnapCal audit`
- [ ] ⛔ **STOP.** Do not start Phase 1 without explicit owner approval.

If SnapCal is unavailable when the other steps finish, Phase 0 is **not** complete.
Either obtain access, or record an owner decision that reuse is dropped entirely — which
closes records A1–A6 as REJECT and makes the persistence decision independently.

---

# Phase gate

- [ ] 1. Build succeeds using the verified command
- [ ] 2. Tests run and pass
- [ ] 3. No skipped, disabled, or expected-failure tests
- [ ] 4. This checklist updated
- [ ] 5. `IMPLEMENTATION_LOG.md` updated
- [ ] 6. Limitations recorded
- [ ] 7. Single commit on `bp-coach`

**Phase 0 is closed only when every box above is ticked.**
**Do not begin Phase 1 without explicit owner approval.**
