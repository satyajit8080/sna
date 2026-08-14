import { cfg } from "../config.js";
import { OpenAIProvider } from "./openai.js";
import { GeminiProvider } from "./gemini.js";
import { MockProvider } from "./mock.js";
import { ProviderError, type AIProvider, type ProviderResponse, type Usage } from "./types.js";

const openai = new OpenAIProvider();
const gemini = new GeminiProvider();
const mock = new MockProvider();

function primary(): AIProvider {
  if (cfg.AI_PROVIDER === "gemini") return gemini;
  if (cfg.AI_PROVIDER === "mock") return mock;
  return openai;
}

function secondary(): AIProvider | null {
  if (cfg.AI_PROVIDER === "openai" && cfg.GEMINI_API_KEY) return gemini;
  if (cfg.AI_PROVIDER === "gemini" && cfg.OPENAI_API_KEY) return openai;
  return null;
}

/**
 * Runs the primary provider; falls over to the secondary on transient failures.
 * Tokens burned by the failed primary are carried into the successful response
 * so nothing goes unbilled, and into the error if both providers fail.
 */
export async function withFailover(
  fn: (p: AIProvider) => Promise<ProviderResponse>
): Promise<ProviderResponse> {
  try {
    return await fn(primary());
  } catch (e: any) {
    const spent: Usage[] = e instanceof ProviderError ? e.usages : [];
    const fb = secondary();
    const transient = e instanceof ProviderError ? e.retryable : e?.name === "TimeoutError";

    if (!fb || !transient) {
      throw e instanceof ProviderError ? e : new ProviderError(String(e?.message ?? e), spent, false);
    }

    try {
      const res = await fn(fb);
      return { result: res.result, usages: [...spent, ...res.usages] };
    } catch (e2: any) {
      const spent2 = e2 instanceof ProviderError ? e2.usages : [];
      throw new ProviderError(String(e2?.message ?? e2), [...spent, ...spent2], false);
    }
  }
}

export const ai = { primary, secondary, withFailover };
export { ProviderError } from "./types.js";
export type { AIProvider, ProviderResponse, Usage } from "./types.js";
