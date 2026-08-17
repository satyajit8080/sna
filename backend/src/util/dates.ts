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


/**
 * Local clock for coaching decisions.
 *
 * Advice that ignores the time of day is wrong however good it is otherwise:
 * a 30-minute gym session is a reasonable recommendation at 6pm and a bad one
 * at 12:21am. The coach cannot infer this — the model has no clock — so it has
 * to be part of the context.
 */
export function localClock(tz: string): {
  hour: number;
  time: string;
  partOfDay: "late_night" | "morning" | "afternoon" | "evening";
} {
  const now = new Date();

  // `Intl` throws a RangeError on an unknown timezone, and the value comes
  // from a client header — so an odd or spoofed X-Timezone would otherwise
  // take down every coach request rather than degrading to UTC.
  const zone = (() => {
    try {
      new Intl.DateTimeFormat("en-GB", { timeZone: tz }).format(now);
      return tz;
    } catch {
      return "UTC";
    }
  })();

  const hour = Number(
    new Intl.DateTimeFormat("en-GB", { timeZone: zone, hour: "2-digit", hour12: false })
      .format(now)
  );

  const time = new Intl.DateTimeFormat("en-GB", {
    timeZone: zone, hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(now);

  // 22:00–04:59 is late night: past the point where training or a large meal
  // is a good idea for most people.
  const partOfDay =
    hour >= 22 || hour < 5 ? "late_night" as const
    : hour < 12 ? "morning" as const
    : hour < 17 ? "afternoon" as const
    : "evening" as const;

  return { hour: Number.isFinite(hour) ? hour : 12, time, partOfDay };
}
