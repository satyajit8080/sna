# BP Coach — specification audit

Current implementation measured against the new spec. No work has been done yet;
this is the "what exists" pass you asked for first.

**Legend** — ✅ working · 🟡 partial · ❌ absent · ⛔ blocked

---

## 0. Blocker before any of this

**The app does not currently build.** Build 26 failed on `SecTaskCreateFromSelf`
(macOS-only API, my error), and HealthKit still aborts on Connect because the
provisioning profile predates the HealthKit capability.

Two fixes are already prepared and unpushed: the `HealthKitService` compile fix
and CI stage R3c, which deletes the stale profile.

Building ~60 new features onto a non-building app compounds every failure. That
gets fixed first.

---

## 1. Feature matrix

### Bottom navigation

| Feature | UI | Data model | Service | Notifications | HealthKit | Working |
|---|---|---|---|---|---|---|
| Home | ✅ | ✅ | ✅ | — | 🟡 | ✅ |
| **Scan** | ❌ | ❌ | ❌ | — | — | ❌ |
| + Add | ✅ | ✅ | ✅ | — | — | ✅ |
| AI Coach | 🟡 | ✅ | ✅ | — | — | 🟡 |
| More | 🟡 | ✅ | ✅ | — | — | 🟡 |

> The spec replaces **History** with **Scan** in the tab bar. See §3 — this is
> the one structural change I would push back on.

### Home

| Feature | Status | Note |
|---|---|---|
| Latest BP, classification, time/source | ✅ | |
| Trend chart | ✅ | Swift Charts, guideline-driven |
| 7 / 30 / 90-day averages | ✅ | Home readings only |
| Today's reading count | ❌ | Trivial to add |
| Steps, resting HR, sleep, active energy | 🟡 | Read; blocked by the entitlement issue |
| Weight | 🟡 | Read but not surfaced on Home |
| Sodium + daily progress | ✅ | |
| Food Scan shortcut | ❌ | Depends on Scan |
| Medication status | ✅ | |
| Medicine reminder status | 🟡 | Adherence shown; next-dose countdown absent |
| AI Coach daily insight | ❌ | Card links to Coach; no insight generated |
| Quick Add | ✅ | |

### Scan — nothing exists

| Feature | Status | What it needs |
|---|---|---|
| Food Scan | ❌ | Camera, a vision model, nutrition mapping |
| Medical Report Scan | ❌ | Camera + `PHPicker` + `UIDocumentPicker`, Vision OCR, AI extraction |
| Prescription Scan | ❌ | OCR + structured extraction + user confirmation |
| Medicine Scan | ❌ | ⚠️ See §3 — highest-risk item in the spec |
| Barcode Scan | ❌ | `AVFoundation` + a barcode→nutrition source |

### + Add

| Feature | Status |
|---|---|
| Blood Pressure | ✅ |
| Rule of 3 | ✅ (exists, not in the spec) |
| Medicine Reminder | ✅ as "Medication" — rename required |
| Food | ✅ |
| Weight | ❌ |
| Activity | ❌ |
| Symptoms | ❌ |
| Doctor Appointment | ❌ — model absent too |

### AI Coach

| Feature | Status | Note |
|---|---|---|
| Text chat | ✅ | Via the Railway gateway |
| Health data sharing | ✅ | Capped, profile-scoped context |
| Conversation history | 🟡 | `AIConversation` model exists, never persisted |
| Photo / camera / file / PDF | ❌ | |
| Voice note | ❌ | Recording + transcription pipeline |
| Suggested questions | ❌ | |
| Daily insight | ❌ | |
| Feedback on messages | ❌ | |
| Safety model | ✅ | Prompt guardrails + output screening + deterministic urgency |

### More

| Feature | Status |
|---|---|
| Apple Health section | 🟡 — needs "Open Health Settings" deep link |
| Notification management | 🟡 — five categories; no quiet hours, no iOS deep link |
| Subscription | ❌ — **removed during the SnapCal audit** (D3, D5, D6) |
| Profile & account | 🟡 — profiles exist; no account, so no deletion |
| Privacy & data | ✅ — export + delete implemented |
| Help & support | ❌ |
| About | 🟡 — version + disclaimer; no What's New or acknowledgements |
| Terms of Use | ❌ |
| App settings | ❌ — no language, theme, or units controls |

### Secondary screens

| Area | Status |
|---|---|
| Blood pressure — add, history, detail, trends, edit/delete, empty states | ✅ |
| Medicine reminder — list, add, schedule, taken/skipped, history | ✅ |
| Doctor appointment | ❌ entirely |
| Symptoms | ❌ entirely |
| Weight | 🟡 stored as a `LifestyleEntry`; no dedicated screens |
| Food | 🟡 log + sodium + trend; no meal detail or scan result |
| Medical reports | ❌ entirely |

### Data models

| Model | Status |
|---|---|
| `BPReading`, `BPMeasurementSession` | ✅ |
| `Medication`, `MedicationDose` | ✅ |
| `LifestyleEntry`, `UserProfile` | ✅ |
| `AIInsight`, `AIConversation`, `AIMessage` | ✅ defined, unused |
| `Appointment` | ❌ |
| `MedicalDocument`, `DoctorReport` | ❌ |
| `SymptomEntry` | ❌ |
| `WeightEntry` | 🟡 via `LifestyleEntry` |

### Backend

| Endpoint | Status |
|---|---|
| `/v1/coach` | ✅ OpenRouter |
| `/v1/food/search`, `/v1/food/:id` | ✅ USDA |
| Vision / image analysis | ❌ |
| OCR assist | ❌ |
| Barcode → nutrition | ❌ |

---

## 2. Rough scale

| Area | New Swift, approx. |
|---|---|
| Scan hub, 5 scanners | 2,000–2,500 |
| Coach attachments, voice, history | 1,200–1,500 |
| Appointments, symptoms, weight, activity | 1,200 |
| Medical reports + OCR | 800–1,000 |
| More: subscription, support, terms, settings | 800 |
| Backend: vision, OCR, barcode | 600 TS |

Against ~7,500 lines today. This is a second build of the app, not a polish pass.

---

## 3. Things I would push back on

Raising these now rather than after they are built.

### Replacing History with Scan in the tab bar

History is where a BP app earns its keep — trends, averages, morning-vs-evening,
home-vs-clinic. Burying it under More to promote a scanner inverts the product's
purpose, and the core loop in the original brief was *Measure → Understand →
Act → Track*.

**Suggestion:** keep History and put Scan inside Add, which is where every other
capture flow already lives.

### Medicine Scan — identify medicine from packaging

The highest-risk item in the spec. Misidentifying a pill and then showing "uses,
instructions and warnings" for the wrong drug is a serious harm, and photo-based
identification is not reliable enough to carry that.

**Suggestion:** scan the packaging to prefill the *name* for user confirmation,
and show drug-class education only after the user confirms. Never assert an
identification.

### Food scan → sodium

Sodium from a photo is a guess. This app already has `ValueProvenance.estimated`
and an `EstimateTag` for exactly this, and any scanned value must carry it — a
guess rendered like a measurement is how someone acts on a wrong number.

### Subscription

The SnapCal audit deliberately removed the paywall and StoreKit (D3, D5, D6).
The spec says "use the existing StoreKit implementation" — there isn't one.
Reintroducing it means new work, and for an app shipping as an *update* to
SnapCal there is a live question about existing subscribers.

### Account deletion

BP Coach has no accounts — local-first, no auth. Apple requires in-app deletion
only for apps that support account *creation*. As it stands this is N/A, and
adding an account system to satisfy it would weaken the privacy position.

### App Store policy notes

- Health claims must stay informational; the existing guardrails cover the AI,
  but scan results need the same discipline.
- Camera, photo library, microphone and speech recognition each need their own
  purpose string. A missing one is a hard crash — the exact failure we are
  fixing right now.
- Nutrition data needs attribution; USDA is public domain, Open Food Facts is
  ODbL with share-alike.

---

## 4. Suggested order

1. **Unblock the build** — the two prepared fixes, confirm HealthKit connects
2. **Navigation + models** — tab structure, `Appointment`, `SymptomEntry`,
   `MedicalDocument`; a migration once, not five times
3. **Add flows** — appointment, symptom, weight, activity. Small, self-contained,
   no external dependencies
4. **Coach** — attachments, voice, persisted history
5. **Scan** — camera, Vision OCR, barcode. Largest and most dependent
6. **More** — support, terms, settings, subscription if confirmed
7. **Polish** — accessibility, Dynamic Type, dark mode, empty and error states

Each stage builds and passes CI before the next. That is what has kept the
existing code honest.
