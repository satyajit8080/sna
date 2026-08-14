export type DetectedFood = {
  name: string;
  /** LLM's portion estimate in grams. Macros are NOT taken from the model. */
  grams: number;
  unit?: string;          // household unit if the model recognised one ("roti", "cup")
  quantity?: number;
  confidence: number;     // 0..1
  cuisine?: string;
  /** Fallback macros, used only if no DB match clears threshold. */
  fallback?: { kcal_100g: number; protein_100g: number; carbs_100g: number; fat_100g: number };
};

export type AnalysisResult = {
  foods: DetectedFood[];
  assumptions: string[];
  confidence: number;
};

export type Usage = {
  model: string;
  inputTokens: number;
  cachedTokens: number;
  outputTokens: number;
  costUsd: number;
  latencyMs: number;
  escalated: boolean;
};

/**
 * `usages` is a list because one logical analysis may bill several provider
 * calls (primary model, then an escalation). Every entry must be recorded or
 * cost reporting under-counts.
 */
export type ProviderResponse = { result: AnalysisResult; usages: Usage[] };

/** Thrown after partial spend so the caller can still bill what was burned. */
export class ProviderError extends Error {
  constructor(message: string, public usages: Usage[] = [], public retryable = true, public status?: number) {
    super(message);
  }
}

export interface AIProvider {
  readonly name: string;
  analyzeImage(jpeg: Buffer, hint?: string): Promise<ProviderResponse>;
  analyzeText(text: string): Promise<ProviderResponse>;
}
