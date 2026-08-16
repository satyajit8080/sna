/**
 * USD per 1M tokens. Verified against vendor pricing pages 2026-08-13.
 * Cached input bills at 10% of standard input on both OpenAI and Google.
 */
export const PRICING: Record<string, { in: number; out: number }> = {
  // Broadly available fallbacks.
  "gpt-4o":      { in: 2.50, out: 10.00 },
  "gpt-4o-mini": { in: 0.15, out: 0.60 },

  // OpenAI — GPT-5.6 family (GA 2026-07-09, Terra/Luna price cut 2026-07-30)
  "gpt-5.6-luna":  { in: 0.20, out: 1.20 },
  "gpt-5.6-terra": { in: 2.00, out: 12.00 },
  "gpt-5.6-sol":   { in: 5.00, out: 30.00 },
  "gpt-5.4-mini":  { in: 0.75, out: 4.50 },
  "gpt-5.4-nano":  { in: 0.20, out: 1.25 },

  // Google
  "gemini-3.6-flash":      { in: 1.50, out: 7.50 },
  "gemini-3.5-flash-lite": { in: 0.30, out: 2.50 },
  "gemini-3.1-pro":        { in: 2.00, out: 12.00 },
};

export const CACHE_DISCOUNT = 0.10;

export function costUsd(model: string, input: number, cached: number, output: number): number {
  const p = PRICING[model] ?? { in: 1, out: 5 };
  const uncached = Math.max(0, input - cached);
  return (
    (uncached * p.in) / 1e6 +
    (cached * p.in * CACHE_DISCOUNT) / 1e6 +
    (output * p.out) / 1e6
  );
}
