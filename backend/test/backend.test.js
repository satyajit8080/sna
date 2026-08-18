import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { loadConfig } from "../dist/config.js";
import { validateCoachRequest, LIMITS } from "../dist/schema.js";
import { screenResponse, renderContext, SCREENED_REPLACEMENT } from "../dist/services/prompt.js";
import { requestCoaching } from "../dist/services/openrouter.js";
import { UpstreamError } from "../dist/services/errors.js";
import { buildApp } from "../dist/app.js";

const baseBody = {
  question: "What moved my blood pressure this week?",
  guidelineName: "ACC/AHA 2017",
  readings: [
    {
      systolic: 128, diastolic: 82, pulse: 72,
      recordedAt: "2026-08-17T07:38:00Z",
      timeOfDay: "Morning", source: "Manual", category: "Elevated", notes: null,
    },
  ],
  averages: [{ days: 7, systolic: 127, diastolic: 83, count: 9 }],
  medications: [],
  lifestyle: [],
};

describe("config", () => {
  test("absent keys become null, never a placeholder string", () => {
    const config = loadConfig({ NODE_ENV: "test" });
    assert.equal(config.openRouterApiKey, null);
    assert.equal(config.usdaApiKey, null);
  });

  test("whitespace-only keys are treated as absent", () => {
    const config = loadConfig({ OPENROUTER_API_KEY: "   ", USDA_FDC_API_KEY: "" });
    assert.equal(config.openRouterApiKey, null);
    assert.equal(config.usdaApiKey, null);
  });

  test("model slug is configurable and has a default", () => {
    assert.ok(loadConfig({}).openRouterModel.length > 0);
    assert.equal(
      loadConfig({ OPENROUTER_MODEL: "openai/gpt-4o-mini" }).openRouterModel,
      "openai/gpt-4o-mini"
    );
  });

  test("defaults are safe when the environment is empty", () => {
    const config = loadConfig({});
    assert.equal(config.port, 8080);
    assert.equal(config.corsOrigins.length, 0);
    assert.ok(config.rateLimit.max > 0);
  });
});

describe("request validation", () => {
  test("accepts a well-formed body", () => {
    const result = validateCoachRequest(baseBody);
    assert.equal(result.ok, true);
  });

  test("rejects a missing question", () => {
    const result = validateCoachRequest({ ...baseBody, question: "" });
    assert.equal(result.ok, false);
  });

  test("rejects a non-object body", () => {
    assert.equal(validateCoachRequest(null).ok, false);
    assert.equal(validateCoachRequest("hello").ok, false);
  });

  test("rejects implausible readings rather than passing them upstream", () => {
    const result = validateCoachRequest({
      ...baseBody,
      readings: [{ ...baseBody.readings[0], systolic: 80, diastolic: 120 }],
    });
    assert.equal(result.ok, false);
  });

  test("rejects out-of-range values", () => {
    const result = validateCoachRequest({
      ...baseBody,
      readings: [{ ...baseBody.readings[0], systolic: 900 }],
    });
    assert.equal(result.ok, false);
  });

  /**
   * The client promises a capped payload. The server verifies it, because a
   * modified or buggy client is exactly the case a cap has to survive.
   */
  test("truncates oversized reading arrays to the server cap", () => {
    const readings = Array.from({ length: 200 }, () => baseBody.readings[0]);
    const result = validateCoachRequest({ ...baseBody, readings });
    assert.equal(result.ok, true);
    assert.equal(result.body.readings.length, LIMITS.maxReadings);
  });

  test("truncates overlong notes instead of forwarding them", () => {
    const result = validateCoachRequest({
      ...baseBody,
      readings: [{ ...baseBody.readings[0], notes: "x".repeat(5000) }],
    });
    assert.equal(result.ok, true);
    assert.ok(result.body.readings[0].notes.length <= LIMITS.maxNotesLength);
  });

  test("rejects an overlong question", () => {
    const result = validateCoachRequest({ ...baseBody, question: "x".repeat(2000) });
    assert.equal(result.ok, false);
  });
});

describe("output screening", () => {
  test("passes ordinary coaching text", () => {
    const result = screenResponse(
      "Your mornings run about 8 points higher than your evenings over the past month."
    );
    assert.equal(result.safe, true);
  });

  test("catches medication change advice", () => {
    for (const text of [
      "You should increase your dose to 10 mg.",
      "Consider stopping your medication for a week.",
      "Try to reduce your dosage slightly.",
    ]) {
      assert.equal(screenResponse(text).safe, false, `not caught: ${text}`);
    }
  });

  test("catches emergency instructions", () => {
    for (const text of [
      "Call 911 immediately.",
      "You should dial 999 now.",
      "This is a medical emergency.",
      "Go to the emergency room right away.",
    ]) {
      assert.equal(screenResponse(text).safe, false, `not caught: ${text}`);
    }
  });

  test("catches diagnosis", () => {
    assert.equal(screenResponse("You likely have hypertension.").safe, false);
  });

  test("the replacement text names no urgency and no medication action", () => {
    assert.equal(screenResponse(SCREENED_REPLACEMENT).safe, true);
  });
});

describe("context rendering", () => {
  test("names the guideline so labels are never ambiguous", () => {
    assert.ok(renderContext(baseBody).includes("ACC/AHA 2017"));
  });

  test("marks estimates explicitly", () => {
    const rendered = renderContext({
      ...baseBody,
      lifestyle: [{ kind: "Sodium", total: 1840, unit: "mg", isEstimate: true }],
    });
    assert.ok(rendered.includes("ESTIMATE"));
  });

  test("does not mark measured values as estimates", () => {
    const rendered = renderContext({
      ...baseBody,
      lifestyle: [{ kind: "Sodium", total: 1200, unit: "mg", isEstimate: false }],
    });
    assert.ok(!rendered.includes("ESTIMATE"));
  });

  test("flags sparse data instead of letting the model fill the gap", () => {
    assert.ok(renderContext(baseBody).includes("fewer than three readings"));
  });

  test("says so plainly when there are no readings at all", () => {
    const rendered = renderContext({ ...baseBody, readings: [] });
    assert.ok(rendered.includes("none recorded"));
  });
});

describe("routes", () => {
  async function app(env = {}) {
    return buildApp(loadConfig({ NODE_ENV: "test", ...env }));
  }

  test("/health is dependency-free and returns ok without any key", async () => {
    const server = await app();
    const response = await server.inject({ method: "GET", url: "/health" });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().status, "ok");
    await server.close();
  });

  test("/ready reports configuration state without echoing secrets", async () => {
    const server = await app({ OPENROUTER_API_KEY: "sk-or-secretvalue987" });
    const response = await server.inject({ method: "GET", url: "/ready" });
    const body = response.body;

    assert.equal(response.statusCode, 200);
    assert.equal(response.json().services.coach, "configured");
    assert.ok(!body.includes("sk-or-secret"), "the response leaked part of the key");
    assert.ok(!body.includes("987"));
    // The model slug is safe to expose and useful when diagnosing.
    assert.ok(response.json().model);
    await server.close();
  });

  test("/v1/coach returns 503 with a clear body when unconfigured", async () => {
    const server = await app();
    const response = await server.inject({
      method: "POST", url: "/v1/coach", payload: baseBody,
    });
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().configured, false);
    await server.close();
  });

  test("/v1/coach rejects an invalid body before reaching the provider", async () => {
    const server = await app({ OPENROUTER_API_KEY: "test-key" });
    const response = await server.inject({
      method: "POST", url: "/v1/coach", payload: { question: "" },
    });
    assert.equal(response.statusCode, 400);
    await server.close();
  });

  test("/v1/food/search returns 503 when unconfigured, never fabricated results", async () => {
    const server = await app();
    const response = await server.inject({ method: "GET", url: "/v1/food/search?q=soup" });
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().configured, false);
    await server.close();
  });

  test("/v1/food/search rejects a too-short query", async () => {
    const server = await app({ USDA_FDC_API_KEY: "test-key" });
    const response = await server.inject({ method: "GET", url: "/v1/food/search?q=a" });
    assert.equal(response.statusCode, 400);
    await server.close();
  });

  test("unknown routes return a structured 404", async () => {
    const server = await app();
    const response = await server.inject({ method: "GET", url: "/nope" });
    assert.equal(response.statusCode, 404);
    assert.ok(response.json().error);
    await server.close();
  });

  test("oversized bodies are refused", async () => {
    const server = await app({ OPENROUTER_API_KEY: "test-key" });
    const response = await server.inject({
      method: "POST",
      url: "/v1/coach",
      payload: { ...baseBody, question: "x".repeat(LIMITS.maxBodyBytes + 1000) },
    });
    assert.ok(response.statusCode === 413 || response.statusCode === 400);
    await server.close();
  });

  test("rate limiting engages after the configured maximum", async () => {
    const server = await app({ RATE_LIMIT_MAX: "3", RATE_LIMIT_WINDOW_MINUTES: "1" });
    let limited = false;
    for (let i = 0; i < 6; i++) {
      const response = await server.inject({ method: "GET", url: "/ready" });
      if (response.statusCode === 429) limited = true;
    }
    assert.ok(limited, "rate limit never engaged");
    await server.close();
  });
});

describe("OpenRouter client", () => {
  const config = loadConfig({ OPENROUTER_API_KEY: "test-key" });
  const validation = validateCoachRequest(baseBody);
  const body = validation.body;

  function stubFetch(status, payload) {
    return async () => new Response(JSON.stringify(payload), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  test("parses an OpenAI-shaped completion", async () => {
    const result = await requestCoaching(body, config, stubFetch(200, {
      model: "anthropic/claude-sonnet-4.5",
      choices: [{ message: { content: "Your mornings run higher than your evenings." } }],
    }));
    assert.equal(result.screened, false);
    assert.match(result.text, /mornings/);
    assert.equal(result.modelUsed, "anthropic/claude-sonnet-4.5");
  });

  test("sends a bearer token, not an x-api-key header", async () => {
    let seen = null;
    await requestCoaching(body, config, async (_url, init) => {
      seen = init.headers;
      return new Response(JSON.stringify({ choices: [{ message: { content: "ok" } }] }),
        { status: 200, headers: { "content-type": "application/json" } });
    });
    assert.equal(seen.authorization, "Bearer test-key");
    assert.equal(seen["x-api-key"], undefined);
  });

  test("screens a prohibited completion before it reaches the client", async () => {
    const result = await requestCoaching(body, config, stubFetch(200, {
      choices: [{ message: { content: "Call 911 immediately." } }],
    }));
    assert.equal(result.screened, true);
    assert.equal(result.text, SCREENED_REPLACEMENT);
    assert.ok(!result.text.includes("911"));
  });

  /**
   * OpenRouter can return HTTP 200 with an error object when a downstream
   * provider fails, so status alone is not a sufficient success check.
   */
  test("treats a 200 carrying an error object as a failure", async () => {
    await assert.rejects(
      () => requestCoaching(body, config, stubFetch(200, {
        error: { message: "provider unavailable", code: 502 },
      })),
      UpstreamError
    );
  });

  test("rejects an empty completion rather than returning blank text", async () => {
    await assert.rejects(
      () => requestCoaching(body, config, stubFetch(200, {
        choices: [{ message: { content: "   " } }],
      })),
      UpstreamError
    );
  });

  test("maps 429 to a retryable error", async () => {
    await assert.rejects(
      () => requestCoaching(body, config, stubFetch(429, {})),
      (error) => error instanceof UpstreamError && error.retryable === true
    );
  });

  test("maps 400 to a non-retryable error", async () => {
    await assert.rejects(
      () => requestCoaching(body, config, stubFetch(400, {})),
      (error) => error instanceof UpstreamError && error.retryable === false
    );
  });

  test("never forwards an upstream error body to the client", async () => {
    await assert.rejects(
      () => requestCoaching(body, config, stubFetch(400, {
        error: { message: "systolic 128 diastolic 82 leaked back" },
      })),
      (error) => !error.message.includes("128")
    );
  });

  test("refuses to call out at all when unconfigured", async () => {
    let called = false;
    await assert.rejects(
      () => requestCoaching(body, loadConfig({}), async () => { called = true; return new Response("{}"); }),
      UpstreamError
    );
    assert.equal(called, false, "made a network call without a key");
  });
});
