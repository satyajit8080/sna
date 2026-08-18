/**
 * All configuration from the environment. Nothing here has a secret default —
 * a missing key means the feature reports itself unavailable rather than
 * half-working with a placeholder.
 */
export interface Config {
  port: number;
  environment: "development" | "production" | "test";
  /** OpenRouter key. Absent => /v1/coach returns 503 with a clear body. */
  openRouterApiKey: string | null;
  /**
   * OpenRouter model slug, e.g. "anthropic/claude-sonnet-4.5".
   * Kept in the environment so switching models or working around a provider
   * outage is a config change, not a redeploy.
   */
  openRouterModel: string;
  /** Sent as HTTP-Referer for OpenRouter attribution. Carries no user data. */
  appReferer: string;
  /** USDA FoodData Central key. Absent => /v1/food returns 503. */
  usdaApiKey: string | null;
  /** Comma-separated allowed origins. Native app traffic has no Origin header. */
  corsOrigins: string[];
  rateLimit: { max: number; windowMinutes: number };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const environment =
    env.NODE_ENV === "production" ? "production"
    : env.NODE_ENV === "test" ? "test"
    : "development";

  return {
    port: parseInt(env.PORT ?? "8080", 10),
    environment,
    openRouterApiKey: env.OPENROUTER_API_KEY?.trim() || null,
    openRouterModel: env.OPENROUTER_MODEL?.trim() || "anthropic/claude-sonnet-4.5",
    appReferer: env.APP_REFERER?.trim() || "https://bpcoach.app",
    usdaApiKey: env.USDA_FDC_API_KEY?.trim() || null,
    corsOrigins: (env.CORS_ORIGINS ?? "").split(",").map(s => s.trim()).filter(Boolean),
    rateLimit: {
      max: parseInt(env.RATE_LIMIT_MAX ?? "30", 10),
      windowMinutes: parseInt(env.RATE_LIMIT_WINDOW_MINUTES ?? "15", 10),
    },
  };
}
