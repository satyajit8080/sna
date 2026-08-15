/** All day boundaries are user-local. The client sends its IANA zone. */
export function localDate(tz: string, at: Date = new Date()): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
  } catch {
    return at.toISOString().slice(0, 10);
  }
}

export function daysAgo(iso: string, n: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}

/**
 * Instant of the user's next local midnight, as UTC ISO.
 *
 * The client uses this to schedule a dashboard refresh exactly at rollover,
 * rather than polling or trusting the device clock to fire a notification.
 */
export function nextLocalMidnight(tz: string, from: Date = new Date()): string {
  const today = localDate(tz, from);
  // Walk forward in hours until the local date changes. Cheap (at most ~26
  // iterations) and correct across DST transitions and half-hour offsets,
  // which naive arithmetic on a UTC offset gets wrong.
  for (let h = 1; h <= 30; h++) {
    const candidate = new Date(from.getTime() + h * 3_600_000);
    if (localDate(tz, candidate) !== today) {
      // Back off to the exact minute the date flips.
      for (let m = 59; m >= 0; m--) {
        const earlier = new Date(candidate.getTime() - m * 60_000);
        if (localDate(tz, earlier) !== today) return earlier.toISOString();
      }
      return candidate.toISOString();
    }
  }
  return new Date(from.getTime() + 864e5).toISOString();
}
