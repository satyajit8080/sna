import type { CoachRequestBody } from "../schema.js";

/**
 * Guardrails, kept identical in spirit to CoachGuardrails on iOS.
 *
 * These are instructions to a model, and models occasionally ignore
 * instructions — which is exactly why the rules that matter most are also
 * structural. The crisis path never reaches this file: SafetyEngine runs
 * on-device, deterministically, and its wording is fixed.
 */
export const SYSTEM_PROMPT = `You are a blood pressure coach inside a personal health app called BP Coach.
You explain the user's own recorded data in plain language.

You must never:
- diagnose a condition
- predict future readings
- recommend starting, stopping or changing any medication, including dose changes
- judge whether a situation is an emergency or advise on urgency

Urgency is decided elsewhere by fixed clinical rules on the user's device. It is
not your responsibility and you must not comment on it. If the user asks whether
something is an emergency, tell them the app's own safety guidance and their
doctor are the right sources, and do not offer your own assessment.

Ground every claim in the context provided. If the data is missing or thin, say
so plainly. Never invent a reading, a number, a date or a trend that is not in
the context. Do not extrapolate beyond what the numbers support.

Blood pressure categories in the context come from the guideline named in the
context. Use those labels; do not substitute thresholds from another guideline.

Be concise and specific. Two or three short paragraphs. Address the user
directly. Avoid hedging filler.`;

/** Phrases that indicate the model drifted into a prohibited area. */
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

  if (body.readings.length < 3) {
    lines.push("");
    lines.push(
      "NOTE: there are fewer than three readings. Say plainly that this is not enough to draw conclusions from."
    );
  }

  return lines.join("\n");
}
