import { z } from "zod";

const Env = z.object({
  NODE_ENV: z.string().default("development"),
  PORT: z.coerce.number().default(8080),
  DATABASE_URL: z.string(),
  JWT_SECRET: z.string().min(32),

  AI_PROVIDER: z.enum(["openai", "gemini", "mock"]).default("openai"),
  AI_MODEL: z.string().default("gpt-4o-mini"),
  AI_ESCALATION_MODEL: z.string().default("gpt-4o"),
  AI_CONFIDENCE_FLOOR: z.coerce.number().default(0.55),
  AI_TIMEOUT_MS: z.coerce.number().default(20_000),
  AI_MAX_RETRIES: z.coerce.number().min(0).max(3).default(1),
  OPENAI_API_KEY: z.string().optional(),
  GEMINI_API_KEY: z.string().optional(),

  // ── OpenRouter: AI Coach only ──────────────────────────────────────────
  // Slugs and prices churn weekly. GET /api/v1/admin/openrouter/models lists
  // the cheapest text models live so this can be set from real data.
  OPENROUTER_API_KEY: z.string().optional(),
  OPENROUTER_COACH_MODEL: z.string().default("meta-llama/llama-3.3-70b-instruct"),
  OPENROUTER_FALLBACK_MODELS_RAW: z.string().default("google/gemini-2.0-flash-001"),
  PUBLIC_APP_URL: z.string().default("https://snapcal.app"),

  // A Data.gov key works for FoodData Central; DEMO_KEY is heavily throttled.
  USDA_FDC_API_KEY: z.string().optional(),
  DATA_GOV_API_KEY: z.string().optional(),
  OPEN_FOOD_FACTS_UA: z.string().default("SnapCalAI/1.0"),

  APPLE_BUNDLE_ID: z.string().default("app.snapcal.ios"),
  PRODUCT_MONTHLY: z.string().default("app.snapcal.pro.monthly"),
  PRODUCT_YEARLY: z.string().default("app.snapcal.pro.yearly"),

  FREE_SCANS_PER_WEEK: z.coerce.number().default(2),
  MAX_UPLOAD_BYTES: z.coerce.number().default(1_572_864),

  // Comma-separated. Empty in production means "no browser origin allowed",
  // which is correct: the only client is the iOS app, which is not origin-bound.
  ALLOWED_ORIGINS: z.string().default(""),
  RUN_MIGRATIONS_ON_BOOT: z.coerce.boolean().default(true),
  ADMIN_USER_IDS: z.string().default(""),
});

function load() {
  const parsed = Env.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n");
    // Fail at boot, not on the first request, so a bad Railway deploy is obvious.
    console.error(`Invalid environment configuration:\n${issues}`);
    process.exit(1);
  }
  return parsed.data;
}

export const cfg = load();
export const isProd = cfg.NODE_ENV === "production";

/** Fallback chain for the coach, tried in order on 429/5xx. */
export const openRouterFallbacks = cfg.OPENROUTER_FALLBACK_MODELS_RAW
  .split(",").map((s) => s.trim()).filter(Boolean);

/** DATA_GOV_API_KEY and USDA_FDC_API_KEY are the same credential. */
export const usdaKey = cfg.USDA_FDC_API_KEY || cfg.DATA_GOV_API_KEY || "DEMO_KEY";

export const allowedOrigins = cfg.ALLOWED_ORIGINS.split(",").map((s) => s.trim()).filter(Boolean);
export const adminUserIds = new Set(cfg.ADMIN_USER_IDS.split(",").map((s) => s.trim()).filter(Boolean));

/** The AI provider selected must actually have a key, or scans 500 at runtime. */
export function assertProviderConfigured() {
  if (cfg.AI_PROVIDER === "openai" && !cfg.OPENAI_API_KEY) {
    throw new Error("AI_PROVIDER=openai but OPENAI_API_KEY is not set");
  }
  if (cfg.AI_PROVIDER === "gemini" && !cfg.GEMINI_API_KEY) {
    throw new Error("AI_PROVIDER=gemini but GEMINI_API_KEY is not set");
  }
}
