import type { Config } from "../config.js";
import type { CoachRequestBody } from "../schema.js";
import { extractAction, type ProposedAction } from "./actions.js";
import { UpstreamError } from "./errors.js";
import {
  SYSTEM_PROMPT,
  APP_CAPABILITIES,
  renderContext,
  screenResponse,
  SCREENED_REPLACEMENT,
} from "./prompt.js";

export interface CoachResult {
  text: string;
  /** A proposal the app will show for confirmation. Never applied server-side. */
  action?: ProposedAction | null;
  screened: boolean;
  screenReason?: string;
  /** Which model actually served the request — OpenRouter may route or fall back. */
  modelUsed?: string;
}

/** OpenAI-compatible chat completions endpoint. */
const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const TIMEOUT_MS = 45_000;

interface OpenRouterResponse {
  model?: string;
  choices?: { message?: { content?: string }; finish_reason?: string }[];
  error?: { message?: string; code?: number | string };
}

/**
 * Calls OpenRouter, which fronts many providers behind one OpenAI-compatible
 * API. The key lives only in the server environment — never in the iOS bundle,
 * where anyone with the .ipa could extract it.
 *
 * Using a gateway rather than a single provider means the model can be changed
 * with an environment variable instead of a code change, and a provider outage
 * is a config edit rather than a redeploy.
 */
export async function requestCoaching(
  body: CoachRequestBody,
  config: Config,
  fetchImpl: typeof fetch = fetch
): Promise<CoachResult> {
  if (!config.openRouterApiKey) {
    throw new UpstreamError("AI provider is not configured", 503, false);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${config.openRouterApiKey}`,
        // OpenRouter uses these for attribution in its dashboard and rankings.
        // Neither carries user data.
        "HTTP-Referer": config.appReferer,
        "X-Title": "BP Coach",
      },
      body: JSON.stringify({
        model: config.openRouterModel,
        max_tokens: 700,
        temperature: 0.3,
        messages: [
          { role: "system", content: `${SYSTEM_PROMPT}\n${APP_CAPABILITIES}` },
          {
            role: "user",
            content: `Here is my data:\n\n${renderContext(body)}\n\nMy question: ${body.question}`,
          },
        ],
      }),
    });
  } catch (error) {
    const aborted = error instanceof Error && error.name === "AbortError";
    throw new UpstreamError(
      aborted ? "The AI service timed out" : "Could not reach the AI service",
      504,
      true
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    // Upstream error bodies can echo the request, and the request contains
    // health data, so nothing from here is forwarded to the client verbatim.
    const retryable = response.status === 429 || response.status >= 500;
    throw new UpstreamError(
      retryable
        ? "The AI service is busy. Try again shortly."
        : "The AI request was rejected.",
      retryable ? 503 : 502,
      retryable
    );
  }

  const payload = (await response.json()) as OpenRouterResponse;

  // OpenRouter can return HTTP 200 with an error object in the body when a
  // downstream provider fails, so the status code alone is not sufficient.
  if (payload.error) {
    throw new UpstreamError("The AI service could not answer that.", 502, true);
  }

  const raw = (payload.choices?.[0]?.message?.content ?? "").trim();
  if (!raw) {
    throw new UpstreamError("The AI service returned an empty response", 502, true);
  }

  // The action block is separated before screening so the JSON cannot trip a
  // pattern, and so a screened reply carries no action with it.
  const { text, action } = extractAction(raw);

  const screen = screenResponse(text);
  if (!screen.safe) {
    return {
      text: SCREENED_REPLACEMENT,
      screened: true,
      screenReason: screen.reason,
      modelUsed: payload.model,
    };
  }
  return { text, action, screened: false, modelUsed: payload.model };
}
