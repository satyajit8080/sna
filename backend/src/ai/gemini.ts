import { cfg } from "../config.js";
import { costUsd } from "./pricing.js";
import { SYSTEM, TEXT_SYSTEM } from "./prompts.js";
import { parseJson } from "../util/json.js";
import { ProviderError, type AIProvider, type AnalysisResult, type ProviderResponse } from "./types.js";

const MODEL = "gemini-3.5-flash-lite";

async function call(system: string, parts: unknown[]) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": cfg.GEMINI_API_KEY ?? "" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: "user", parts }],
        generationConfig: { responseMimeType: "application/json", maxOutputTokens: 400, temperature: 0.2 },
      }),
      signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
    }
  );
  if (!res.ok) throw new ProviderError(`gemini ${res.status}`, [], res.status >= 500 || res.status === 429, res.status);
  const json: any = await res.json();
  const raw = json.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? "").join("") ?? "";
  return { raw, usage: json.usageMetadata ?? {} };
}

function normalise(raw: string): AnalysisResult {
  const j = parseJson<any>(raw) ?? {};
  const foods = Array.isArray(j.foods) ? j.foods : [];
  return {
    foods: foods.slice(0, 12).map((f: any) => ({
      name: String(f?.name ?? "").trim().slice(0, 80),
      grams: Math.max(1, Math.min(2000, Number(f?.grams) || 100)),
      unit: f?.unit ?? undefined,
      quantity: f?.quantity ?? undefined,
      cuisine: f?.cuisine ?? undefined,
      confidence: Math.max(0, Math.min(1, Number(f?.confidence) || 0.5)),
    })).filter((f: any) => f.name),
    assumptions: (Array.isArray(j.assumptions) ? j.assumptions : []).slice(0, 3).map(String),
    confidence: Math.max(0, Math.min(1, Number(j.confidence) || 0)),
  };
}

function usageOf(u: any, started: number) {
  const input = u.promptTokenCount ?? 0;
  const cached = u.cachedContentTokenCount ?? 0;
  const output = u.candidatesTokenCount ?? 0;
  return {
    model: MODEL, inputTokens: input, cachedTokens: cached, outputTokens: output,
    costUsd: costUsd(MODEL, input, cached, output), latencyMs: Date.now() - started, escalated: false,
  };
}

export class GeminiProvider implements AIProvider {
  readonly name = "gemini";

  async analyzeImage(jpeg: Buffer): Promise<ProviderResponse> {
    const started = Date.now();
    const { raw, usage } = await call(SYSTEM, [
      { inline_data: { mime_type: "image/jpeg", data: jpeg.toString("base64") } },
    ]);
    return { result: normalise(raw), usages: [usageOf(usage, started)] };
  }

  async analyzeText(text: string): Promise<ProviderResponse> {
    const started = Date.now();
    const { raw, usage } = await call(TEXT_SYSTEM, [{ text: text.slice(0, 400) }]);
    return { result: normalise(raw), usages: [usageOf(usage, started)] };
  }
}
