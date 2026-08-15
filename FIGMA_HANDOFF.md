# SnapCal — Figma Handoff Specification

Read this **before** you finalise the design. Following it means I can implement
screens directly; deviating from it means I guess, and guesses become rework.

The backend and app architecture stay the source of truth for *behaviour*.
Figma becomes the source of truth for *appearance*. Where a design implies a
behaviour change (new data, new endpoint, new state), flag it — I'll tell you
whether it's cheap or expensive before you commit to it.

---

## 1. What to send me — in priority order

**Best: a Figma link.** I have a Figma connector available. With a file URL and
node ID I can read frames, variables, styles, component structure and Auto
Layout directly — far more accurate than any screenshot. Send links in this
shape, one per screen:

```
https://www.figma.com/design/<fileKey>/SnapCal?node-id=<nodeId>
```

Get a node ID by selecting a frame → right-click → **Copy link to selection**.

If the connector fails or the file isn't shared with the account, I'll say so
immediately and fall back to the list below.

**Fallback bundle, in order of usefulness:**

| Rank | Artefact | Format | Why |
|---|---|---|---|
| 1 | Design tokens | JSON (Variables → export, or Tokens Studio) | Colors/spacing/type as data, not pixels |
| 2 | Screen exports | PNG @2x, one file per screen **per state** | Layout reference |
| 3 | Screen spec table | Markdown or CSV | Exact values I can't measure from a PNG |
| 4 | Icons | SVG, individual files | Vector, recolourable |
| 5 | Flow diagram | PNG or FigJam link | Navigation structure |

**What I cannot use:** `.fig` files, Figma prototype recordings, a single
mega-PNG of every screen, or a PDF export of the whole file. Screenshots pasted
into chat work for a quick question but are the worst input for implementation
— I can't read exact hex, spacing, or font weight from them reliably.

---

## 2. Figma file structure

### Pages

```
00 · Cover
01 · Foundations      colors, type, spacing, radii, elevation
02 · Components       buttons, cards, inputs, chips, tab bar, rings, charts
03 · Screens          one section per feature, matching the code
04 · States           loading / empty / error variants
05 · Flows            FigJam-style navigation diagrams
06 · Assets           icons, illustrations, logos
```

### Naming — this matters most

Frame names become my file map. Name screen frames **exactly** after the
existing SwiftUI views so I know what I'm replacing:

```
Screen/Dashboard              → Features/Dashboard/DashboardView.swift
Screen/Coach                  → Features/Coach/CoachView.swift
Screen/MealPlanner            → Features/MealPlanner/MealPlannerView.swift
Screen/Diary                  → Features/Diary/DiaryView.swift
Screen/Progress               → Features/History/ProgressHubView.swift
Screen/Settings               → Features/Settings/SettingsView.swift
Screen/Paywall                → Features/Paywall/PaywallView.swift
Screen/Onboarding/{Step}      → Features/Onboarding/OnboardingFlow.swift
Screen/Scan/{Capture|Analyzing|Confirm}
Screen/Welcome                → Features/Onboarding/WelcomeView.swift
Screen/NotificationSettings   → Features/Notifications/NotificationSettingsView.swift
```

Components use `Category/Name`:

```
Button/Primary          Card/Metric           Ring/Calorie
Button/Secondary        Card/Meal             Chart/Bar
Button/Tertiary         Card/Premium          Chart/Line
Input/Text              Card/Coach            TabBar/Item
Chip/Macro              List/DiaryRow         Badge/Usage
```

If a name has no obvious code counterpart, that's a signal it's a genuinely new
component — call it out so we can budget for it.

### Variables and Auto Layout

- **Everything on Auto Layout.** A frame without it tells me nothing about how
  it reflows on a 6.1" vs 6.9" screen. Absolutely-positioned layers get
  hardcoded and break on other devices.
- Use **Figma Variables** for color, spacing and radius — not raw hex on layers.
  Variables export as JSON; raw hex doesn't.
- **Two modes** on the color collection: `Light` and `Dark`. The app supports
  both. If you only design light, I'll derive dark and you may not like it.
- Constrain frames to **393 × 852** (iPhone 16 logical points). Also give me one
  screen at **440 × 956** if any layout is non-obvious at the larger size.

---

## 3. Design tokens — map to what exists

The app has a token layer in `Core/Theme.swift`. Reuse these names and I change
values only; invent new names and I change code everywhere.

| Figma variable | Code | Current |
|---|---|---|
| `color/accent` | `Theme.accent` | `#14B87A` |
| `color/accent-soft` | `Theme.accentSoft` | accent @ 14% |
| `color/protein` | `Theme.protein` | `#3B82F6` |
| `color/carbs` | `Theme.carbs` | `#F59E0B` |
| `color/fat` | `Theme.fat` | `#EC4899` |
| `color/danger` | `Theme.danger` | `#EF4444` |
| `color/bg` | `Theme.bg` | `#FAFAF8` / `#0B0B0C` |
| `color/card` | `Theme.card` | `#FFFFFF` / `#161618` |
| `color/hairline` | `Theme.hairline` | primary @ 7% |
| `space/xs · s · m · l · xl` | `Theme.Space.*` | 4 · 8 · 16 · 24 · 32 |
| `radius/card · control · pill` | `Theme.Radius.*` | 20 · 14 · 999 |

**Type.** The app uses SF Pro / SF Rounded at these sizes. If you design in a
different family, tell me now — a custom font is a real change (bundling,
licensing, dynamic type behaviour), not a token swap.

| Figma style | Code | Size / weight |
|---|---|---|
| `text/hero` | `.hero` | 56 bold rounded, monospaced digits |
| `text/big-num` | `.bigNum` | 30 semibold rounded, monospaced digits |
| `text/title` | `.title` | 22 semibold |
| `text/body` | `.body_` | 16 regular |
| `text/label` | `.label` | 13 medium |
| `text/caption` | `.caption_` | 12 regular |

Numeric readouts (calories, macros, weight, steps) **must** use monospaced
digits or they jitter as values animate. If your design shows a proportional
font on a counter, I'll override it.

If you want a different palette — the purple/lavender direction in your
reference, say — change the variable **values** and keep the names. That's a
one-file change on my side.

---

## 4. States — the part most handoffs skip

For every screen that loads data, give me a frame per state. Name them
`Screen/Name — State`. Missing states are where implementations diverge from
designs, and this app has real ones: quota exhaustion, offline scans, AI
failures.

**Required for every data screen:**

| State | Frame suffix | Must show |
|---|---|---|
| Loading | `— Loading` | Skeleton or spinner. Say which. |
| Empty (first-time) | `— Empty` | Copy + primary action |
| Populated | *(base frame)* | Realistic data, not lorem |
| Error / API failure | `— Error` | Message + retry affordance |
| Offline | `— Offline` | Only if it differs from Error |

**Screen-specific states I need:**

- `Screen/Dashboard — Empty` — nothing logged today
- `Screen/Dashboard — Over` — calories exceeded (the ring changes colour)
- `Screen/Coach — Empty` — no messages yet, suggestion chips
- `Screen/Coach — Thinking` — awaiting AI response
- `Screen/Coach — Limit` — free questions spent
- `Screen/MealPlanner — Locked` — free user preview
- `Screen/Scan — Analyzing` — the 2-3s AI wait
- `Screen/Scan — NoFood` — AI found nothing
- `Screen/Confirm — LowConfidence` — AI unsure, prompt to check
- `Screen/Paywall` — one frame per context: `FoodScan`, `Coach`, `MealPlan`,
  `General`. Copy differs per context.
- `Screen/Progress — Free` vs `— Premium` — weekly report is gated

**Component states.** Every interactive component needs variants for
`default / pressed / disabled / selected` where applicable. Use Figma
**variants** with a `state` property, not separate frames.

---

## 5. Navigation and flows

The app is a 6-tab `TabView` with modal sheets. Document flows as a FigJam
diagram or an annotated frame, showing for each transition:

- **Trigger** — tap, swipe, system event, notification
- **Presentation** — push / sheet / full-screen cover / tab switch
- **Dismissal** — swipe down, X button, automatic on success
- **Back behaviour** — where does the user land

Mark deep-link destinations explicitly. These already exist:

```
snapcal://today    snapcal://scan    snapcal://coach
snapcal://meals    snapcal://premium
```

Don't build a clickable prototype for my benefit — I can't traverse it. A
static diagram with labelled arrows is more useful and faster to make.

---

## 6. Dynamic data — use real shapes

**Never use placeholder text on data-bound elements.** Use values that match
what the API actually returns, so I can see how the layout copes.

| Element | Use | Also design |
|---|---|---|
| Calories | `1,847` | `0`, `12,450` (4-digit overflow) |
| Weight | `70.3 kg` | `—` when unlogged, and lb variant |
| Food name | `Paneer butter masala` | a 40-char name that must truncate |
| Macro | `92g` | `0g`, `250g` |
| Steps | `8,543` | `0`, `24,102` |
| Coach reply | 40-60 words | 1 sentence, and a 4-line answer |
| Usage badge | `2 free AI scans available` | `1 free scan remaining`, `Premium Feature` |
| Meal list | 3 items | 1 item, 12 items (scroll) |
| Chart | 7 bars | 1 bar, 90 bars |

Longest and shortest realistic content, always. A design that only shows the
happy middle is where truncation bugs come from.

**Regional food matters.** This app targets US/CA/UK/AU/IN. Show `Roti × 2`,
`Dal tadka`, `Bhindi masala` alongside western items — Devanagari-adjacent
transliterations and longer names are the ones that break layouts.

**Don't design data we don't have.** If a card shows "muscle mass" or "sleep
score", I have no source for it. Check with me first; adding a data source is
backend work, not a design change.

---

## 7. Assets

| Asset | Format | Notes |
|---|---|---|
| Icons | **SF Symbols where possible** — give me the symbol name | Free, scales, supports Dynamic Type, dark mode |
| Custom icons | SVG, 24×24 artboard, single colour, no embedded fills | I recolour in code |
| Illustrations | SVG preferred, PNG @1x/@2x/@3x acceptable | Say if it should tint with the theme |
| App icon | 1024×1024 PNG, no alpha, no rounded corners | Apple applies the mask |
| Logo | SVG + PNG @3x | Light and dark variants |
| Lottie | JSON + a reference MP4 | Adds a dependency — confirm with me first |
| Photos | Not from Figma | Licensing; send source + licence separately |

Deliver as a folder or zip: `Assets/Icons/`, `Assets/Illustrations/`, etc.
Filename = layer name = what I'll call it in the asset catalog. `arrow-right.svg`,
not `Vector 47.svg`.

**Prefer SF Symbols.** The app already uses them throughout. A custom SVG that
duplicates an SF Symbol costs bundle size and loses Dynamic Type for nothing.

---

## 8. My limitations — read this

- **Figma link:** works via the connector, assuming the file is shared with the
  connected account. This is the best path. If it fails I'll tell you at once
  rather than guessing.
- **Screenshots:** I can see them and judge layout, hierarchy and rough
  spacing. I **cannot** reliably read exact hex values, font weights, or
  spacing in pixels from an image. Anything precise must come as text.
- **`.fig` files:** I can't open them.
- **Prototypes:** I can't click through them.
- **The real constraint:** I have no Xcode. I cannot compile or run the app or
  see a rendered screen. Every visual change is verified by you on device, via
  TestFlight. Budget for 2-3 rounds per screen.

That last point should shape how you sequence the work.

---

## 9. Recommended workflow

Don't design all 15 screens then hand them over at once. That maximises the
blast radius of any misunderstanding, and given the build loop, a bad
assumption compounds.

**Phase 1 — Foundations only.** Send the token JSON and one screen (Dashboard,
all states). I implement the token layer and that screen. You review on
TestFlight. This surfaces disagreements about type scale, spacing rhythm and
dark mode when they cost one file to fix.

**Phase 2 — Components.** Buttons, cards, chips, tab bar. I build them as
reusable SwiftUI views. Everything after this gets faster.

**Phase 3 — Screens, in dependency order.** Dashboard → Scan flow → Confirm →
Diary → Coach → Meals → Progress → Settings → Paywall → Onboarding.

**Phase 4 — Polish.** Animation timing, transitions, haptics, empty-state copy.

Ship each phase to TestFlight before starting the next.

---

## 10. What not to change without telling me

These are load-bearing for reasons that aren't visual:

- **"AI estimate, not medical advice" disclaimers** — App Store review risk.
  They can move and restyle; they can't disappear.
- **Restore Purchases, Terms, Privacy on the paywall** — Apple requires them.
- **Account deletion in Settings** — required because the app creates accounts.
- **Permission priming screens** (camera, notifications, HealthKit) — asking
  cold burns the single system prompt iOS grants.
- **Usage badges** (`2 free AI scans available`) — text comes from the backend
  and changes with configured limits. Design the container, not the string.
- **Six-tab structure** — changing it is fine, but it's a routing change, not a
  visual one. Flag it.

---

## Checklist before you send

- [ ] Colors, spacing, radii are Figma **Variables**, with Light + Dark modes
- [ ] Type styles named to match the table in §3
- [ ] Every frame on Auto Layout
- [ ] Screen frames named `Screen/<CodeViewName>`
- [ ] Loading / Empty / Error frames for every data screen
- [ ] Component variants for pressed / disabled / selected
- [ ] Realistic data, including longest and shortest cases
- [ ] Indian and western food names both represented
- [ ] Icons listed as SF Symbol names, or exported as SVG
- [ ] Flow diagram with triggers, presentation style and dismissal
- [ ] Anything requiring new backend data called out explicitly
