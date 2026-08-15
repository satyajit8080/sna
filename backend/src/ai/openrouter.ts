import { cfg, openRouterFallbacks } from "../config.js";
import { ProviderError, type Usage } from "./types.js";

const BASE = "https://openrouter.ai/api/v1";

/**
 * OpenRouter client, used for the AI Coach only.
 *
 * Food scanning stays on OpenAI: vision quality matters there and the cost is
 * already low. Coaching is short text, asked often, and is the one place where
 * a $0.01/M model is genuinely good enough — so it runs on whatever cheap model
 * OPENROUTER_COACH_MODEL names.
 *
 * OpenRouter's API is OpenAI-compatible, so this is a thin wrapper.
 */

export type ChatMessage = { role: "system" | "user" | "assistant"; content: string };

type Choice = { message?: { content?: string }; finish_reason?: string };

export type OpenRouterResult = { text: string; usage: Usage };

/** Falls back down the list on 429/5xx — cheap models are the flakiest. */
function modelChain(): string[] {
  return [cfg.OPENROUTER_COACH_MODEL, ...openRouterFallbacks]
    .map((m) => m.trim())
    .filter(Boolean);
}

async function callModel(model: string, messages: ChatMessage[], maxTokens: number): Promise<OpenRouterResult> {
  const started = Date.now();

  const res = await fetch(`${BASE}/chat/completions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${cfg.OPENROUTER_API_KEY}`,
      // OpenRouter uses these for attribution and abuse handling.
      "HTTP-Referer": cfg.PUBLIC_APP_URL,
      "X-Title": "SnapCal",
    },
    body: JSON.stringify({
      model,
      messages,
      max_tokens: maxTokens,
      temperature: 0.3,
      // One short line. `stop` guards against a chatty model ignoring the
      // system prompt and rambling past the first sentence.
      stop: ["\n\n"],
    }),
    signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
  });

  if (!res.ok) {
    const retryable = res.status >= 500 || res.status === 429 || res.status === 402;
    throw new ProviderError(`openrouter ${res.status} (${model})`, [], retryable, res.status);
  }

  const json: any = await res.json();
  const text = (json.choices as Choice[] | undefined)?.[0]?.message?.content ?? "";

  const u = json.usage ?? {};
  // OpenRouter reports actual spend on the generation, which beats guessing
  // from a price table that changes weekly.
  const costUsd = Number(u.cost ?? 0);

  return {
    text,
    usage: {
      model: json.model ?? model,
      inputTokens: u.prompt_tokens ?? 0,
      cachedTokens: u.prompt_tokens_details?.cached_tokens ?? 0,
      outputTokens: u.completion_tokens ?? 0,
      costUsd,
      latencyMs: Date.now() - started,
      escalated: false,
    },
  };
}

export async function chat(messages: ChatMessage[], maxTokens = 60): Promise<OpenRouterResult> {
  // Mock mode keeps CI and simulator builds working with no key and no spend.
  if (cfg.AI_PROVIDER === "mock" || !cfg.OPENROUTER_API_KEY) {
    if (cfg.AI_PROVIDER !== "mock") {
      throw new ProviderError("openrouter_not_configured", [], false, 503);
    }
    return {
      text: "You have room left today — a bowl of dal with two rotis keeps you on target.",
      usage: {
        model: "mock", inputTokens: 0, cachedTokens: 0, outputTokens: 0,
        costUsd: 0, latencyMs: 15, escalated: false,
      },
    };
  }

  const chain = modelChain();
  let last: unknown;

  for (const model of chain) {
    try {
      return await callModel(model, messages, maxTokens);
    } catch (e: any) {
      last = e;
      const transient = e instanceof ProviderError ? e.retryable : e?.name === "TimeoutError";
      if (!transient) break;
    }
  }

  throw last instanceof ProviderError
    ? last
    : new ProviderError(String((last as any)?.message ?? last), [], false);
}

/**
 * Lists the cheapest text models OpenRouter currently serves.
 *
 * Model slugs and prices churn constantly, so rather than hardcoding a
 * "cheapest model" that goes stale, this powers an admin endpoint you can hit
 * to pick the right value for OPENROUTER_COACH_MODEL.
 */
export async function cheapestModels(limit = 15) {
  const res = await fetch(`${BASE}/models`, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) throw new ProviderError(`openrouter ${res.status}`, [], true, res.status);

  const json: any = await res.json();
  const rows = (json.data ?? [])
    .filter((m: any) => {
      const modality = m.architecture?.input_modalities ?? m.architecture?.modality ?? "";
      const isText = Array.isArray(modality) ? modality.includes("text") : String(modality).includes("text");
      const prompt = Number(m.pricing?.prompt ?? Infinity);
      return isText && Number.isFinite(prompt);
    })
    .map((m: any) => ({
      id: m.id,
      name: m.name,
      context: m.context_length,
      // OpenRouter quotes per-token; per-million is what everyone reasons in.
      input_per_1m: Number(m.pricing.prompt) * 1e6,
      output_per_1m: Number(m.pricing.completion ?? 0) * 1e6,
      free: Number(m.pricing.prompt) === 0,
    }))
    .sort((a: any, b: any) =>
      (a.input_per_1m + a.output_per_1m) - (b.input_per_1m + b.output_per_1m));

  return {
    configured: cfg.OPENROUTER_COACH_MODEL,
    fallbacks: openRouterFallbacks,
    // Free models are listed but rate-limited (~200 req/day), so they are
    // shown for reference rather than recommended for production.
    cheapest_paid: rows.filter((r: any) => !r.free).slice(0, limit),
    free: rows.filter((r: any) => r.free).slice(0, 5),
  };
}
