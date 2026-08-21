/**
 * Actions the coach can propose.
 *
 * The model does not write to the user's data. It proposes a structured action;
 * the app renders a confirmation card; the user taps to accept. That separation
 * is the whole design, and it is not negotiable for a health app:
 *
 * - A misheard date creates a wrong appointment. Annoying but recoverable.
 * - A misheard dose creates a wrong medication schedule with reminders telling
 *   someone to take the wrong amount. That is not recoverable by an undo button,
 *   because the reminder is what they will trust at 8am.
 *
 * So every action is a proposal, every proposal is validated here before it can
 * even be shown, and anything the model was not explicitly told is left blank
 * rather than guessed.
 */

export type ProposedAction =
  | AddMedicationAction
  | AddAppointmentAction
  | AddReadingAction
  | AddWeightAction
  | AddSymptomAction;

export interface AddMedicationAction {
  kind: "addMedication";
  name: string;
  /** Free text as the user said it: "5mg", "half a tablet". Never invented. */
  dose: string;
  frequency:
    | "onceDaily"
    | "twiceDaily"
    | "threeTimesDaily"
    | "everyOtherDay"
    | "weekly"
    | "asNeeded";
  /** Minutes past midnight, e.g. 480 for 08:00. */
  reminderTimes: number[];
  notes?: string;
}

export interface AddAppointmentAction {
  kind: "addAppointment";
  doctorName: string;
  /** ISO 8601. Must be in the future. */
  scheduledFor: string;
  specialty?: string;
  location?: string;
  notes?: string;
}

export interface AddReadingAction {
  kind: "addReading";
  systolic: number;
  diastolic: number;
  pulse?: number;
  /** ISO 8601. Defaults to now if absent. Never in the future. */
  recordedAt?: string;
  notes?: string;
}

export interface AddWeightAction {
  kind: "addWeight";
  kilograms: number;
}

export interface AddSymptomAction {
  kind: "addSymptom";
  /** Must match one of the app's known symptom kinds. */
  symptom: string;
  severity: "mild" | "moderate" | "severe";
  notes?: string;
}

const FREQUENCIES = new Set([
  "onceDaily", "twiceDaily", "threeTimesDaily",
  "everyOtherDay", "weekly", "asNeeded",
]);

const SYMPTOMS = new Set([
  "headache", "dizziness", "fatigue", "palpitations", "swelling",
  "chestDiscomfort", "breathlessness", "blurredVision", "nausea", "other",
]);

const SEVERITIES = new Set(["mild", "moderate", "severe"]);

/**
 * Validates a proposed action.
 *
 * Rejection is the safe default: an action that cannot be fully validated is
 * discarded and the user simply gets the text reply, which is no worse than the
 * behaviour before actions existed.
 */
export function validateAction(raw: unknown): ProposedAction | null {
  if (!raw || typeof raw !== "object") return null;
  const a = raw as Record<string, unknown>;

  switch (a.kind) {
    case "addMedication": {
      const name = text(a.name, 80);
      const dose = text(a.dose, 60);
      // A medication without a dose is not a medication. The model is told to
      // ask rather than assume, and if it assumed anyway, this stops it.
      if (!name || !dose) return null;
      if (typeof a.frequency !== "string" || !FREQUENCIES.has(a.frequency)) return null;

      const times = Array.isArray(a.reminderTimes)
        ? a.reminderTimes
            .map(Number)
            .filter((n) => Number.isInteger(n) && n >= 0 && n < 1440)
            .slice(0, 6)
        : [];

      return {
        kind: "addMedication",
        name,
        dose,
        frequency: a.frequency as AddMedicationAction["frequency"],
        reminderTimes: times,
        notes: text(a.notes, 300) || undefined,
      };
    }

    case "addAppointment": {
      const doctorName = text(a.doctorName, 80);
      if (!doctorName) return null;

      const when = isoDate(a.scheduledFor);
      // An appointment in the past is a parsing failure, not a record.
      if (!when || when.getTime() <= Date.now()) return null;
      // Two years out is almost certainly a year that was misread.
      if (when.getTime() > Date.now() + 730 * 86_400_000) return null;

      return {
        kind: "addAppointment",
        doctorName,
        scheduledFor: when.toISOString(),
        specialty: text(a.specialty, 60) || undefined,
        location: text(a.location, 120) || undefined,
        notes: text(a.notes, 300) || undefined,
      };
    }

    case "addReading": {
      const systolic = Math.round(Number(a.systolic));
      const diastolic = Math.round(Number(a.diastolic));
      // The same plausibility rules the app applies to manual entry. A reading
      // that fails these is a transcription error, not a measurement.
      if (!Number.isFinite(systolic) || systolic < 60 || systolic > 300) return null;
      if (!Number.isFinite(diastolic) || diastolic < 30 || diastolic > 200) return null;
      if (systolic <= diastolic) return null;

      const pulse = Math.round(Number(a.pulse));
      const when = a.recordedAt ? isoDate(a.recordedAt) : null;
      if (when && when.getTime() > Date.now() + 60_000) return null;

      return {
        kind: "addReading",
        systolic,
        diastolic,
        pulse: Number.isFinite(pulse) && pulse >= 30 && pulse <= 220 ? pulse : undefined,
        recordedAt: when?.toISOString(),
        notes: text(a.notes, 300) || undefined,
      };
    }

    case "addWeight": {
      const kilograms = Number(a.kilograms);
      if (!Number.isFinite(kilograms) || kilograms < 20 || kilograms > 400) return null;
      return { kind: "addWeight", kilograms: Math.round(kilograms * 10) / 10 };
    }

    case "addSymptom": {
      const symptom = text(a.symptom, 40);
      if (!symptom || !SYMPTOMS.has(symptom)) return null;
      const severity = typeof a.severity === "string" ? a.severity : "";
      if (!SEVERITIES.has(severity)) return null;
      return {
        kind: "addSymptom",
        symptom,
        severity: severity as AddSymptomAction["severity"],
        notes: text(a.notes, 300) || undefined,
      };
    }

    default:
      return null;
  }
}

function text(value: unknown, max: number): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function isoDate(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/**
 * Pulls an action block out of the model's reply.
 *
 * The model is asked to append a fenced JSON block. Anything unparseable is
 * dropped silently — the text reply still stands, and no action is proposed.
 */
export function extractAction(raw: string): {
  text: string;
  action: ProposedAction | null;
} {
  const match = raw.match(/```action\s*([\s\S]*?)```/);
  if (!match) return { text: raw.trim(), action: null };

  const text = raw.replace(match[0], "").trim();

  let parsed: unknown;
  try {
    parsed = JSON.parse(match[1].trim());
  } catch {
    return { text, action: null };
  }

  return { text, action: validateAction(parsed) };
}
