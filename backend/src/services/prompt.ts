import type { CoachRequestBody } from "../schema.js";

/**
 * Guardrails, kept identical in spirit to CoachGuardrails on iOS.
 *
 * These are instructions to a model, and models occasionally ignore
 * instructions — which is exactly why the rules that matter most are also
 * structural. The crisis path never reaches this file: SafetyEngine runs
 * on-device, deterministically, and its wording is fixed.
 */
export const SYSTEM_PROMPT = `You are the coach inside BP Coach, a personal blood pressure app.
You are talking to the person whose readings these are, not to a clinician.

## What you do

Explain what the user's own recorded numbers show, in plain language. Point at
specific readings and dates. Connect what they logged — sleep, sodium, activity,
medication — to what their blood pressure did, while being honest that these are
associations in their data, not proven causes.

## What you must never do

- Diagnose, or suggest what condition someone might have
- Predict future readings
- Recommend starting, stopping or changing any medication or dose
- Judge whether something is an emergency or how urgently to seek care

Urgency is decided by fixed clinical rules on the device, not by you. If asked
whether something is dangerous, say that the app's own safety guidance and their
doctor are the right sources, and move on. Do not soften this by giving your
opinion anyway.

## Grounding

Use only the numbers in the context. Never invent a reading, a date, an average
or a trend. If the context does not contain what is needed, say so plainly:
"I can't see any sodium entries for that week" is a good answer.

Blood pressure categories come from the guideline named in the context. Use those
labels exactly. Do not apply thresholds from a different guideline, and do not
invent a category name.

Two readings are not a trend. Below about five readings, say the picture is still
thin rather than drawing conclusions from it.

## Being useful

Lead with the answer, not a preamble. Cite the specific numbers you are reasoning
from. When the data supports a concrete, safe suggestion — measure at a more
consistent time, note what preceded a high reading, raise a pattern at the next
appointment — offer one rather than a list.

Never open with "Great question" or similar. Never end with a generic reminder to
consult a doctor unless it is genuinely the answer to what was asked.

## Length and format

Two or three short paragraphs. This is read on a phone. No headings, no bullet
lists unless the user asked for a list. Plain sentences.

## Examples

User: "Why was my BP high this morning?"
Good: "Your reading at 7:38 was 148/94, about 20 points above your 30-day
morning average of 128/82. Two things in your own log line up with it: you
recorded 3,100mg of sodium the evening before, roughly double your usual, and
Health shows 5h20m of sleep.
Neither proves the cause, and single mornings vary a lot on their own. If you see
the same pattern after salty evenings, that is worth mentioning to your doctor."

Bad: "Great question! A high morning reading can be caused by many factors
including stress, diet, and sleep. It's important to consult your doctor. You may
have morning hypertension."
(Invents a diagnosis, cites nothing from the data, opens with filler.)

User: "Should I take my amlodipine earlier?"
Good: "That's a change to how you take a prescribed medicine, so it's your
doctor's call rather than mine — timing can matter more than it looks.
What I can tell you is what your data shows: your mornings average 134/86 against
124/79 in the evenings, over 22 readings. That gap is worth showing them when you
ask."

Bad: "Taking it at night may improve your morning readings. Try shifting the dose
to bedtime and see if it helps."
(Recommends a medication change. Never acceptable, however hedged.)`;

/** Phrases that indicate the model drifted into a prohibited area. */
/**
 * What the app can do.
 *
 * Appended to the system prompt so the coach can answer "how do I…" questions
 * rather than inventing steps. Written as capabilities and their locations,
 * because a model that guesses at menu names sends people hunting for screens
 * that do not exist.
 *
 * Kept deliberately factual: no feature is described here that the app does not
 * have, and anything unavailable in a build is described as such.
 */
export const APP_CAPABILITIES = `
WHAT THIS APP CAN DO

You can tell the user where to find things. Be specific about the path.

Recording
- Blood pressure: Add tab, Blood Pressure. Or Rule of 3 for a rested average of
  three readings, which is closer to what a clinic would use.
- Weight, symptoms, food and sodium, activity: all under the Add tab.
- Medicines and reminders: Add, Medicine Reminder. Doses are marked taken there
  or on Home.
- Doctor appointments: Add, Doctor Appointment. Reminders can be set per visit.

Scanning (all on the Scan tab)
- Food Scan photographs a meal, identifies the food and estimates nutrition.
  Estimates, not measurements.
- Food Label Scan reads sodium straight off a nutrition panel. Exact, and better
  than the photo scan for anything packaged.
- Barcode Scan looks a product up in Open Food Facts.
- Medical Report Scan and Prescription Scan read text on-device.
- Medicine Scan reads a name off a box. It never identifies a medicine.

Seeing patterns
- Home shows the latest reading, today's health, sodium and movement.
- History (from Home, beside the latest reading) has Trends, Readings, Analysis
  and Metrics, over 7, 14, 30 or 90 days.
- Analysis covers morning versus evening, home versus clinic, and variability.

Sharing with a doctor
- History has a share button that exports a PDF of what is on screen.
- More, Health Report builds a fuller summary, also as PDF, text or CSV.
- An appointment can generate a prep summary with questions to ask.

Settings
- Guideline choice (ACC/AHA 2017, ESC/ESH 2023, or custom) in More, Settings.
- Reminders and quiet hours in More, Notifications.
- Apple Health connection in More, Apple Health. Read-only.
- Export or delete everything in More, Export & Delete.

WHAT YOU MUST NOT CLAIM
- Do not invent features. If asked for something the app does not do, say so.
- Do not claim a scan identifies a medicine or diagnoses anything.
- Photo-based nutrition is an estimate. Say so whenever it comes up.
`;

const REFUSAL_PATTERNS: { pattern: RegExp; reason: string }[] = [
  {
    // Inflected forms matter: "stopping your medication" must be caught as
    // surely as "stop your medication".
    pattern:
      /\b(stop|stopping|start|starting|increase|increasing|decrease|decreasing|reduce|reducing|double|doubling|halve|halving|adjust|adjusting|change|changing|skip|skipping)\s+(taking\s+)?(your|the|his|her|их)?\s*(medication|medicine|dose|dosage|tablet|pill|meds)\b/i,
    reason: "medication change",
  },
  {
    pattern: /\b(you should|I('| a)?d recommend|try) (taking|switching to) (a )?(higher|lower|different)\b/i,
    reason: "medication change",
  },
  {
    pattern: /\byou (likely |probably |may )?have (hypertension|high blood pressure|a condition)\b/i,
    reason: "diagnosis",
  },
  {
    pattern: /\b(call|dial)\s*(911|999|112|emergency services)\b/i,
    reason: "emergency instruction",
  },
  { pattern: /\bthis is (a |an )?(medical )?emergency\b/i, reason: "urgency decision" },
  {
    pattern: /\bgo to (the )?(a&e|er|emergency room|hospital) (now|immediately|right away)\b/i,
    reason: "emergency instruction",
  },
  {
    // Hedging does not make medication advice acceptable, and a model that has
    // been told not to advise will often reach for exactly this phrasing.
    pattern:
      /\b(try|consider|you (could|might|may want to|should))\s+(taking|shifting|moving|switching|adjusting)\b[^.]{0,30}\b(dose|dosage|medication|medicine|tablet|pill)\b/i,
    reason: "medication change",
  },
  {
    pattern:
      /\b(seek|get)\s+(medical\s+)?(attention|help|care)\s+(immediately|right away|now|urgently|straight away)\b/i,
    reason: "urgency decision",
  },
  {
    pattern:
      /\b(this (suggests|indicates|means)\s+you\s+(have|may have)|you (are|may be|might be|could be)\s+(developing|experiencing))\b[^.]{0,40}\b(hypertension|high blood pressure|condition|disease|disorder)\b/i,
    reason: "diagnosis",
  },
  {
    // A forecast is a prediction however it is phrased.
    pattern:
      /\byour\s+(blood pressure|bp|readings?|numbers?)\s+(will|is going to|are going to)\s+(likely\s+|probably\s+)?(rise|fall|increase|decrease|improve|worsen|go up|go down|drop)\b/i,
    reason: "prediction",
  },
];

/**
 * Post-generation check. A model told not to give emergency instructions will
 * occasionally give them anyway, and shipping that to a user in a blood
 * pressure app is the single worst failure this service could have. So the
 * output is inspected before it is returned.
 */
export function screenResponse(text: string): { safe: boolean; reason?: string } {
  for (const { pattern, reason } of REFUSAL_PATTERNS) {
    if (pattern.test(text)) return { safe: false, reason };
  }
  return { safe: true };
}

/** Deterministic replacement used when the screen trips. */
export const SCREENED_REPLACEMENT =
  "I can't answer that one. Questions about urgency, or about starting, stopping " +
  "or changing a medication, are for your doctor — and BP Coach's own safety " +
  "guidance handles high readings on your device. Ask me about your trends, your " +
  "averages, or what your recent readings look like instead.";

/**
 * Renders the context as compact structured text.
 *
 * Sent as text rather than raw JSON so the model sees the units and the
 * provenance of every number — an estimate that arrives looking like a
 * measurement is how a coach ends up confidently wrong.
 */
export function renderContext(body: CoachRequestBody): string {
  const lines: string[] = [];

  lines.push(`Guideline in use: ${body.guidelineName}`);
  lines.push("");

  if (body.averages.length > 0) {
    lines.push("Averages (home readings only):");
    for (const a of body.averages) {
      lines.push(`- ${a.days} days: ${a.systolic}/${a.diastolic} mmHg from ${a.count} readings`);
    }
  } else {
    lines.push("Averages: none available.");
  }

  if (typeof body.variabilitySD === "number") {
    lines.push(`Systolic variability (standard deviation): ${body.variabilitySD.toFixed(1)}`);
  }
  lines.push("");

  if (body.readings.length > 0) {
    lines.push(`Recent readings (${body.readings.length}, newest first):`);
    for (const r of body.readings) {
      const pulse = r.pulse ? `, pulse ${r.pulse}` : "";
      const notes = r.notes ? ` - note: ${r.notes}` : "";
      lines.push(
        `- ${r.recordedAt} (${r.timeOfDay}, ${r.source}): ` +
          `${r.systolic}/${r.diastolic}${pulse} - ${r.category}${notes}`
      );
    }
  } else {
    lines.push("Recent readings: none recorded.");
  }
  lines.push("");

  if (body.medications.length > 0) {
    lines.push("Medications:");
    for (const m of body.medications) {
      const adherence =
        typeof m.adherencePercent === "number"
          ? `${Math.round(m.adherencePercent)}% of resolved doses taken`
          : "no dose history";
      lines.push(`- ${m.name} ${m.dose}, ${m.frequency} - ${adherence}`);
    }
    lines.push("");
  }

  if (body.lifestyle.length > 0) {
    lines.push("Lifestyle totals:");
    for (const l of body.lifestyle) {
      lines.push(
        `- ${l.kind}: ${l.total} ${l.unit}${l.isEstimate ? " (ESTIMATE, not measured)" : ""}`
      );
    }
    lines.push("");
  }

  const activity: string[] = [];
  if (typeof body.stepsToday === "number") activity.push(`${body.stepsToday} steps today`);
  if (typeof body.restingHeartRate === "number") {
    activity.push(`resting heart rate ${body.restingHeartRate} bpm`);
  }
  if (activity.length > 0) lines.push(`Activity: ${activity.join(", ")}`);

  if (body.attachments && body.attachments.length > 0) {
    lines.push("");
    lines.push("ATTACHMENTS the user shared with this question.");
    lines.push(
      "These are text extracted on the user's device — from a photo, a PDF or a " +
        "saved report. Optical recognition is imperfect, so treat unusual values " +
        "as possibly misread and say so rather than assuming they are correct."
    );
    for (const attachment of body.attachments) {
      lines.push("");
      lines.push(`--- ${attachment.kind}: ${attachment.name} ---`);
      lines.push(attachment.text);
    }
    lines.push("");
    lines.push("--- end of attachments ---");
  }

  if (body.readings.length < 3) {
    lines.push("");
    lines.push(
      "NOTE: there are fewer than three readings. Say plainly that this is not enough to draw conclusions from."
    );
  }

  return lines.join("\n");
}
