import { cfg } from "../config.js";
import { costUsd } from "./pricing.js";
import { SYSTEM, TEXT_SYSTEM } from "./prompts.js";
import { parseJson } from "../util/json.js";
import { ProviderError, type AIProvider, type AnalysisResult, type ProviderResponse, type Usage } from "./types.js";

const RESPONSES_URL = "https://api.openai.com/v1/responses";
const CHAT_URL = "https://api.openai.com/v1/chat/completions";

/**
 * Models that exist on essentially every account. Used when the configured
 * model is rejected — a wrong AI_MODEL should degrade to a working scan, not
 * fail every request.
 */
const SAFE_VISION_MODELS = ["gpt-4o", "gpt-4o-mini"];

type Call = { raw: string; usage: Usage };

/** Chat Completions shape — broadly available, used as the fallback path. */
async function callChat(model: string, system: string, content: unknown[],
                        started: number, escalated: boolean): Promise<Call> {
  const messages = [
    { role: "system", content: system },
    {
      role: "user",
      content: content.map((c: any) =>
        c.type === "input_image"
          ? { type: "image_url", image_url: { url: c.image_url, detail: "low" } }
          : { type: "text", text: c.text }),
    },
  ];

  const res = await fetch(CHAT_URL, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${cfg.OPENAI_API_KEY}` },
    body: JSON.stringify({
      model, messages, max_tokens: 400,
      response_format: { type: "json_object" },
    }),
    signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    const err = new ProviderError(`openai chat ${res.status} (${model}): ${detail.slice(0, 300)}`,
                                  [], res.status >= 500 || res.status === 429, res.status);
    (err as any).providerStatus = res.status;
    (err as any).providerBody = detail.slice(0, 500);
    throw err;
  }

  const json: any = await res.json();
  const u = json.usage ?? {};
  const input = u.prompt_tokens ?? 0;
  const cached = u.prompt_tokens_details?.cached_tokens ?? 0;
  const output = u.completion_tokens ?? 0;

  return {
    raw: json.choices?.[0]?.message?.content ?? "",
    usage: {
      model: json.model ?? model,
      inputTokens: input, cachedTokens: cached, outputTokens: output,
      costUsd: costUsd(model, input, cached, output),
      latencyMs: Date.now() - started,
      escalated,
    },
  };
}

async function callOnce(model: string, system: string, content: unknown[], started: number, escalated: boolean): Promise<Call> {
  const res = await fetch(RESPONSES_URL, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${cfg.OPENAI_API_KEY}` },
    body: JSON.stringify({
      model,
      instructions: system,               // static → prompt-cached at 10% input rate
      input: [{ role: "user", content }],
      max_output_tokens: 400,
      text: { format: { type: "json_object" } },
    }),
    signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
  });

  if (!res.ok) {
    const retryable = res.status >= 500 || res.status === 429;
    const detail = await res.text().catch(() => "");
    const err = new ProviderError(`openai ${res.status} (${model}): ${detail.slice(0, 300)}`,
                                  [], retryable, res.status);
    (err as any).providerStatus = res.status;
    (err as any).providerBody = detail.slice(0, 500);
    throw err;
  }

  const json: any = await res.json();
  const raw =
    json.output_text ??
    json.output?.flatMap((o: any) => o.content ?? []).find((c: any) => c.type === "output_text")?.text ??
    "";

  const u = json.usage ?? {};
  const input = u.input_tokens ?? 0;
  const cached = u.input_tokens_details?.cached_tokens ?? 0;
  const output = u.output_tokens ?? 0;

  return {
    raw,
    usage: {
      model,
      inputTokens: input,
      cachedTokens: cached,
      outputTokens: output,
      costUsd: costUsd(model, input, cached, output),
      latencyMs: Date.now() - started,
      escalated,
    },
  };
}

/** Retries only transient failures, with jittered backoff, bounded by AI_MAX_RETRIES. */
/**
 * Tries the configured model on the Responses API, then the same model on Chat
 * Completions, then known-good vision models.
 *
 * A 400/404 means the account cannot use that model — retrying it is pointless,
 * but the scan can still succeed elsewhere. This is what turned a mistyped
 * AI_MODEL into "Something went wrong" on every single scan.
 */
async function call(model: string, system: string, content: unknown[], escalated = false): Promise<Call> {
  const attempts: Array<{ model: string; fn: typeof callOnce }> = [
    { model, fn: callOnce },
    { model, fn: callChat },
    ...SAFE_VISION_MODELS
      .filter((m) => m !== model)
      .map((m) => ({ model: m, fn: callChat })),
  ];

  let last: unknown;

  for (const attempt of attempts) {
    for (let retry = 0; retry <= cfg.AI_MAX_RETRIES; retry++) {
      const started = Date.now();
      try {
        return await attempt.fn(attempt.model, system, content, started, escalated);
      } catch (e: any) {
        last = e;
        const status = e?.providerStatus ?? e?.status;
        const transient = e instanceof ProviderError ? e.retryable : e?.name === "TimeoutError";

        // 401 is a bad key: no other model will help.
        if (status === 401 || status === 403) throw e;
        // 400/404 means this model is unusable — move on immediately.
        if (status === 400 || status === 404) break;
        if (!transient || retry === cfg.AI_MAX_RETRIES) break;

        await new Promise((r) => setTimeout(r, 250 * 2 ** retry + Math.random() * 200));
      }
    }
  }

  throw last;
}

function normalise(raw: string): AnalysisResult {
  const j = parseJson<any>(raw) ?? {};
  const foods = Array.isArray(j.foods) ? j.foods : [];
  return {
    foods: foods
      .filter((f: any) => f && typeof f.name === "string" && f.name.trim())
      .slice(0, 12)
      .map((f: any) => ({
        name: String(f.name).trim().slice(0, 80),
        grams: Math.max(1, Math.min(2000, Number(f.grams) || 100)),
        unit: typeof f.unit === "string" ? f.unit.slice(0, 20) : undefined,
        quantity: Number.isFinite(Number(f.quantity)) ? Number(f.quantity) : undefined,
        cuisine: typeof f.cuisine === "string" ? f.cuisine.slice(0, 20) : undefined,
        confidence: Math.max(0, Math.min(1, Number(f.confidence) || 0.5)),
      })),
    assumptions: (Array.isArray(j.assumptions) ? j.assumptions : []).slice(0, 3).map((a: unknown) => String(a).slice(0, 140)),
    confidence: Math.max(0, Math.min(1, Number(j.confidence) || 0)),
  };
}

export class OpenAIProvider implements AIProvider {
  readonly name = "openai";

  async analyzeImage(jpeg: Buffer, hint?: string): Promise<ProviderResponse> {
    const content: unknown[] = [
      { type: "input_image", image_url: `data:image/jpeg;base64,${jpeg.toString("base64")}`, detail: "low" },
    ];
    if (hint) content.push({ type: "input_text", text: hint.slice(0, 120) });

    const usages: Usage[] = [];

    let primary: Call;
    try {
      primary = await call(cfg.AI_MODEL, SYSTEM, content);
    } catch (e: any) {
      throw new ProviderError(e?.message ?? "primary failed", usages, e?.retryable ?? true, e?.status);
    }
    usages.push(primary.usage);
    let result = normalise(primary.raw);

    // Escalate only when it matters (~8% of scans). BOTH calls are billed and
    // both are returned, so cost accounting reflects real spend.
    if (result.confidence < cfg.AI_CONFIDENCE_FLOOR || result.foods.length === 0) {
      try {
        const second = await call(cfg.AI_ESCALATION_MODEL, SYSTEM, content, true);
        usages.push(second.usage);
        const better = normalise(second.raw);
        if (better.confidence >= result.confidence) result = better;
      } catch {
        // Escalation is best-effort — keep the primary answer rather than failing.
      }
    }

    return { result, usages };
  }

  async analyzeText(text: string): Promise<ProviderResponse> {
    try {
      const c = await call(cfg.AI_MODEL, TEXT_SYSTEM, [{ type: "input_text", text: text.slice(0, 400) }]);
      return { result: normalise(c.raw), usages: [c.usage] };
    } catch (e: any) {
      throw new ProviderError(e?.message ?? "text analysis failed", [], e?.retryable ?? true, e?.status);
    }
  }
}
