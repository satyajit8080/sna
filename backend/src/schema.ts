/**
 * Request validation for the coach endpoint.
 *
 * The shape mirrors BPContextSnapshot on iOS, with hard caps enforced
 * server-side as well: the client promises a bounded payload, and the server
 * verifies the promise rather than trusting it.
 */

export const LIMITS = {
  maxReadings: 30,          // matches AIContextEngine.readingLimit on iOS
  maxMedications: 20,
  maxLifestyle: 12,
  maxQuestionLength: 1_000,
  maxNotesLength: 200,
  maxAttachments: 4,
  /** Per attachment. A long report would otherwise crowd out the readings. */
  maxAttachmentChars: 6_000,
  maxBodyBytes: 256 * 1024,
} as const;

export interface CoachReading {
  systolic: number;
  diastolic: number;
  pulse?: number | null;
  recordedAt: string;
  timeOfDay: string;
  source: string;
  category: string;
  notes?: string | null;
}

export interface CoachAttachment {
  kind: string;
  name: string;
  text: string;
}

export interface CoachRequestBody {
  question: string;
  guidelineName: string;
  attachments?: CoachAttachment[];
  readings: CoachReading[];
  averages: { days: number; systolic: number; diastolic: number; count: number }[];
  variabilitySD?: number | null;
  medications: { name: string; dose: string; frequency: string; adherencePercent?: number | null }[];
  lifestyle: { kind: string; total: number; unit: string; isEstimate: boolean }[];
  stepsToday?: number | null;
  restingHeartRate?: number | null;
}

export interface ValidationFailure { field: string; message: string }

function isPlausibleReading(r: CoachReading): boolean {
  return Number.isInteger(r.systolic) && Number.isInteger(r.diastolic)
    && r.systolic >= 60 && r.systolic <= 300
    && r.diastolic >= 30 && r.diastolic <= 200
    && r.systolic > r.diastolic;
}

/**
 * Validates and — where safe — trims rather than rejects. Oversized arrays are
 * truncated to the cap (the cap is the contract); malformed values are hard
 * failures. Returns either a cleaned body or a list of failures.
 */
export function validateCoachRequest(
  raw: unknown
): { ok: true; body: CoachRequestBody } | { ok: false; failures: ValidationFailure[] } {
  const failures: ValidationFailure[] = [];
  const b = raw as Partial<CoachRequestBody> | null;

  if (!b || typeof b !== "object") {
    return { ok: false, failures: [{ field: "body", message: "Request body must be a JSON object" }] };
  }

  if (typeof b.question !== "string" || b.question.trim().length === 0) {
    failures.push({ field: "question", message: "question is required" });
  } else if (b.question.length > LIMITS.maxQuestionLength) {
    failures.push({ field: "question", message: `question exceeds ${LIMITS.maxQuestionLength} characters` });
  }

  if (typeof b.guidelineName !== "string" || !b.guidelineName) {
    failures.push({ field: "guidelineName", message: "guidelineName is required" });
  }

  if (!Array.isArray(b.readings)) {
    failures.push({ field: "readings", message: "readings must be an array" });
  } else {
    for (const [index, reading] of b.readings.entries()) {
      if (!isPlausibleReading(reading)) {
        failures.push({ field: `readings[${index}]`, message: "implausible blood pressure values" });
      }
      if (reading.notes && reading.notes.length > LIMITS.maxNotesLength) {
        reading.notes = reading.notes.slice(0, LIMITS.maxNotesLength);
      }
    }
  }

  if (failures.length > 0) return { ok: false, failures };

  // Attachments arrive as text the device already extracted. Anything that is
  // not a string is dropped rather than forwarded — the client is trusted to
  // send text, but not trusted to be correct about it.
  const attachments = Array.isArray(b.attachments)
    ? b.attachments
        .filter(
          (a): a is CoachAttachment =>
            !!a && typeof a.text === "string" && a.text.trim().length > 0
        )
        .slice(0, LIMITS.maxAttachments)
        .map((a) => ({
          kind: typeof a.kind === "string" ? a.kind.slice(0, 40) : "file",
          name: typeof a.name === "string" ? a.name.slice(0, 120) : "attachment",
          text: a.text.slice(0, LIMITS.maxAttachmentChars),
        }))
    : [];

  const body = b as CoachRequestBody;
  return {
    ok: true,
    body: {
      ...body,
      attachments,
      readings: body.readings.slice(0, LIMITS.maxReadings),
      medications: (body.medications ?? []).slice(0, LIMITS.maxMedications),
      lifestyle: (body.lifestyle ?? []).slice(0, LIMITS.maxLifestyle),
      averages: body.averages ?? [],
    },
  };
}
