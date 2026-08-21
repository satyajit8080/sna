import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { loadConfig } from "../dist/config.js";
import { validateCoachRequest, LIMITS } from "../dist/schema.js";
import { parseDetectedFoods } from "../dist/services/vision.js";
import { lookupBarcode } from "../dist/services/barcode.js";
import {
  screenResponse, renderContext, SCREENED_REPLACEMENT, SYSTEM_PROMPT,
} from "../dist/services/prompt.js";
import { requestCoaching } from "../dist/services/openrouter.js";
import { UpstreamError } from "../dist/services/errors.js";
import { buildApp } from "../dist/app.js";
import { extractAction } from "../dist/services/actions.js";

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

  /** Hedging does not make medication advice acceptable. */
  test("catches softened medication advice", () => {
    for (const text of [
      "You might want to try taking your dose at night.",
      "Consider shifting the medication to the evening.",
      "You could try moving your tablet to bedtime.",
    ]) {
      assert.equal(screenResponse(text).safe, false, `not caught: ${text}`);
    }
  });

  test("catches urgency framed as advice", () => {
    for (const text of [
      "You should seek medical attention immediately.",
      "Get care right away.",
    ]) {
      assert.equal(screenResponse(text).safe, false, `not caught: ${text}`);
    }
  });

  test("catches predictions about future readings", () => {
    assert.equal(
      screenResponse("Your blood pressure will likely improve next week.").safe,
      false
    );
  });

  /** The screen must not fire on ordinary, useful coaching. */
  test("legitimate answers still pass", () => {
    for (const text of [
      "Your reading at 7:38 was 148/94, about 20 points above your 30-day average.",
      "That is a change to a prescribed medicine, so it is your doctor's call rather than mine.",
      "I can't see any sodium entries for that week.",
      "Your mornings average 134/86 against 124/79 in the evenings, over 22 readings.",
      "Two readings is not enough to call a trend yet.",
    ]) {
      assert.equal(screenResponse(text).safe, true, `false positive: ${text}`);
    }
  });

  test("the system prompt states the hard limits explicitly", () => {
    for (const phrase of ["never", "diagnos", "medication", "urgency"]) {
      assert.match(SYSTEM_PROMPT.toLowerCase(), new RegExp(phrase));
    }
  });

  test("the system prompt carries worked examples", () => {
    assert.match(SYSTEM_PROMPT, /Good:/);
    assert.match(SYSTEM_PROMPT, /Bad:/);
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

describe("attachments", () => {
  const withAttachments = (attachments) => ({ ...baseBody, attachments });

  test("valid attachments are accepted and normalised", () => {
    const result = validateCoachRequest(
      withAttachments([{ kind: "report", name: "Blood test", text: "LDL 118 mg/dL" }])
    );
    assert.equal(result.ok, true);
    assert.equal(result.body.attachments.length, 1);
    assert.equal(result.body.attachments[0].kind, "report");
  });

  test("a body with no attachments still validates", () => {
    const result = validateCoachRequest(baseBody);
    assert.equal(result.ok, true);
    assert.deepEqual(result.body.attachments, []);
  });

  /** The client is trusted to send text, not trusted to be right about it. */
  test("attachments without usable text are dropped, not forwarded", () => {
    const result = validateCoachRequest(
      withAttachments([
        { kind: "photo", name: "a", text: "" },
        { kind: "photo", name: "b", text: "   " },
        { kind: "photo", name: "c" },
        { kind: "photo", name: "d", text: "real content here" },
      ])
    );
    assert.equal(result.ok, true);
    assert.equal(result.body.attachments.length, 1);
    assert.equal(result.body.attachments[0].name, "d");
  });

  test("attachment count is capped", () => {
    const many = Array.from({ length: 20 }, (_, i) => ({
      kind: "photo", name: `p${i}`, text: "content",
    }));
    const result = validateCoachRequest(withAttachments(many));
    assert.equal(result.body.attachments.length, LIMITS.maxAttachments);
  });

  test("attachment text is truncated to the cap", () => {
    const result = validateCoachRequest(
      withAttachments([{ kind: "document", name: "long", text: "x".repeat(50_000) }])
    );
    assert.equal(result.body.attachments[0].text.length, LIMITS.maxAttachmentChars);
  });

  test("non-string fields are replaced rather than passed through", () => {
    const result = validateCoachRequest(
      withAttachments([{ kind: 42, name: null, text: "content" }])
    );
    assert.equal(result.body.attachments[0].kind, "file");
    assert.equal(result.body.attachments[0].name, "attachment");
  });

  test("a non-array attachments field is ignored", () => {
    const result = validateCoachRequest({ ...baseBody, attachments: "nope" });
    assert.equal(result.ok, true);
    assert.deepEqual(result.body.attachments, []);
  });

  /**
   * The model must be told recognition can be wrong, or it will read an OCR
   * artefact as a real lab value.
   */
  test("rendered context warns that extracted text may be misread", () => {
    const rendered = renderContext(
      withAttachments([{ kind: "report", name: "Labs", text: "Creatinine 2.4" }])
    );
    assert.match(rendered, /misread|imperfect/i);
    assert.ok(rendered.includes("Creatinine 2.4"));
  });

  test("no attachment section appears when there are none", () => {
    assert.ok(!renderContext(baseBody).includes("ATTACHMENTS"));
  });
});

describe("barcode lookup", () => {
  const offResponse = (product) => ({
    ok: true,
    json: async () => (product ? { status: 1, product } : { status: 0 }),
  });

  test("maps a product with sodium recorded directly", async () => {
    const item = await lookupBarcode("3017620422003", async () =>
      offResponse({
        code: "3017620422003",
        product_name: "Test Spread",
        brands: "TestBrand",
        serving_size: "15 g",
        nutriments: { sodium_100g: 0.107, "energy-kcal_100g": 539 },
      })
    );
    assert.equal(item.sodiumMilligramsPer100g, 107);
    assert.equal(item.energyKilocaloriesPer100g, 539);
    assert.equal(item.defaultServingGrams, 15);
    assert.match(item.source, /Open Food Facts/);
  });

  /** Many entries record salt rather than sodium; deriving it beats nothing. */
  test("derives sodium from salt when sodium is absent", async () => {
    const item = await lookupBarcode("1234567890", async () =>
      offResponse({
        code: "1234567890",
        product_name: "Salty Snack",
        nutriments: { salt_100g: 1.5 },
      })
    );
    assert.equal(item.sodiumMilligramsPer100g, 600); // 1.5g salt ≈ 600mg sodium
  });

  /** A blood pressure app has no use for a product with no sodium figure. */
  test("returns null when no sodium figure exists", async () => {
    const item = await lookupBarcode("1234567890", async () =>
      offResponse({ code: "1", product_name: "Mystery", nutriments: {} })
    );
    assert.equal(item, null);
  });

  test("returns null for an unknown product", async () => {
    assert.equal(await lookupBarcode("1234567890", async () => offResponse(null)), null);
  });

  test("returns null for a product with no name", async () => {
    const item = await lookupBarcode("1234567890", async () =>
      offResponse({ code: "1", nutriments: { sodium_100g: 0.5 } })
    );
    assert.equal(item, null);
  });

  /** Rejecting non-digits keeps arbitrary strings out of the upstream URL. */
  test("rejects anything that is not a barcode without calling out", async () => {
    let called = false;
    const spy = async () => { called = true; return offResponse(null); };
    for (const code of ["abc", "12", "'; DROP TABLE--", "", "1".repeat(20)]) {
      assert.equal(await lookupBarcode(code, spy), null);
    }
    assert.equal(called, false, "an invalid barcode reached the network");
  });

  test("an upstream error returns null rather than throwing", async () => {
    const item = await lookupBarcode("1234567890", async () => ({ ok: false }));
    assert.equal(item, null);
  });

  test("serving sizes without grams leave the figure null", async () => {
    const item = await lookupBarcode("1234567890", async () =>
      offResponse({
        code: "1", product_name: "Biscuit",
        serving_size: "1 biscuit",
        nutriments: { sodium_100g: 0.3 },
      })
    );
    assert.equal(item.defaultServingGrams, null);
  });
});

describe("food photo analysis", () => {
  test("parses a well-formed reply", () => {
    const items = parseDetectedFoods(
      '{"items":[{"name":"grilled chicken breast","estimatedGrams":120,"confidence":"high"}]}'
    );
    assert.equal(items.length, 1);
    assert.equal(items[0].name, "grilled chicken breast");
    assert.equal(items[0].estimatedGrams, 120);
  });

  /** Models wrap JSON in fences despite being told not to. */
  test("strips markdown fences", () => {
    const items = parseDetectedFoods(
      '```json\n{"items":[{"name":"rice","estimatedGrams":150,"confidence":"medium"}]}\n```'
    );
    assert.equal(items.length, 1);
    assert.equal(items[0].name, "rice");
  });

  test("ignores prose around the JSON", () => {
    const items = parseDetectedFoods(
      'Here is what I found:\n{"items":[{"name":"salad","estimatedGrams":80,"confidence":"low"}]}\nHope that helps!'
    );
    assert.equal(items.length, 1);
    assert.equal(items[0].confidence, "low");
  });

  test("accepts a bare array", () => {
    const items = parseDetectedFoods('[{"name":"apple","estimatedGrams":180,"confidence":"high"}]');
    assert.equal(items.length, 1);
  });

  /** A parse failure must never become a fabricated result. */
  test("unparseable output yields nothing rather than a guess", () => {
    for (const raw of ["", "I cannot see any food", "{broken", "null", "42"]) {
      assert.deepEqual(parseDetectedFoods(raw), []);
    }
  });

  test("an empty plate returns no items", () => {
    assert.deepEqual(parseDetectedFoods('{"items":[]}'), []);
  });

  /** An absurd portion would distort the day's total; clamp it. */
  test("clamps implausible portions", () => {
    const items = parseDetectedFoods(
      '{"items":[{"name":"soup","estimatedGrams":999999,"confidence":"high"}]}'
    );
    assert.equal(items[0].estimatedGrams, 2000);
  });

  test("a missing or invalid portion falls back to 100g", () => {
    const items = parseDetectedFoods(
      '{"items":[{"name":"bread","confidence":"high"},{"name":"jam","estimatedGrams":-5,"confidence":"high"}]}'
    );
    assert.equal(items[0].estimatedGrams, 100);
    assert.equal(items[1].estimatedGrams, 100);
  });

  test("an unknown confidence value becomes medium", () => {
    const items = parseDetectedFoods(
      '{"items":[{"name":"pasta","estimatedGrams":200,"confidence":"very sure"}]}'
    );
    assert.equal(items[0].confidence, "medium");
  });

  test("nameless entries are dropped", () => {
    const items = parseDetectedFoods(
      '{"items":[{"name":"","estimatedGrams":100},{"name":"x","estimatedGrams":100},{"name":"egg","estimatedGrams":50}]}'
    );
    assert.equal(items.length, 1);
    assert.equal(items[0].name, "egg");
  });

  test("the item count is capped", () => {
    const many = Array.from({ length: 40 }, (_, i) => ({
      name: `food ${i}`, estimatedGrams: 50, confidence: "high",
    }));
    assert.equal(parseDetectedFoods(JSON.stringify({ items: many })).length, 12);
  });
});

describe("first day with no data", () => {
  const base = {
    question: "Is my blood pressure normal?",
    guidelineName: "ACC/AHA 2017",
    readings: [], averages: [], medications: [], lifestyle: [], attachments: [],
  };

  /// Refusing to engage on day one is the worst thing the coach can do, so the
  /// instruction must actively tell it not to.
  test("an empty log tells the model to coach rather than refuse", () => {
    const rendered = renderContext(base);
    assert.match(rendered, /Do not simply refuse/);
    assert.match(rendered, /Ask how they are doing/);
    assert.match(rendered, /Add tab, Blood Pressure/);
  });

  test("a first name is addressed to the model", () => {
    const rendered = renderContext({ ...base, firstName: "Satya" });
    assert.match(rendered, /talking to Satya/);
  });

  test("no name means no name line", () => {
    assert.doesNotMatch(renderContext(base), /talking to/);
  });

  /// One or two readings is not a trend, but it is not nothing either.
  test("a sparse log asks for usefulness, not just a caveat", () => {
    const rendered = renderContext({
      ...base,
      readings: [{ systolic: 128, diastolic: 82, recordedAt: "2026-08-01T09:00:00Z",
                   timeOfDay: "morning", source: "manual", category: "Elevated" }],
    });
    assert.match(rendered, /not enough/);
    assert.match(rendered, /be useful anyway/);
  });

  test("only a first name survives validation", () => {
    const result = validateCoachRequest({ ...base, firstName: "  Satya Kumar Dhumal  " });
    assert.equal(result.ok, true);
    assert.equal(result.body.firstName, "Satya");
  });

  test("a blank name is dropped", () => {
    for (const value of ["", "   ", null, 42]) {
      const result = validateCoachRequest({ ...base, firstName: value });
      assert.equal(result.ok, true);
      assert.equal(result.body.firstName, undefined);
    }
  });
});

describe("potassium screening", () => {
  /**
   * Increasing dietary potassium is standard blood pressure advice and is
   * genuinely dangerous for a subset of this app's users: reduced kidney
   * function, ACE inhibitors, ARBs, potassium-sparing diuretics. The app cannot
   * identify those people from what it stores, so an unqualified suggestion must
   * never reach anyone.
   */
  test("instructions to increase potassium are blocked", () => {
    for (const text of [
      "Try to increase your potassium intake with bananas and spinach.",
      "Adding more potassium-rich foods can help lower blood pressure.",
      "You could get more potassium from leafy greens.",
      "Eating potassium-rich foods is a good next step.",
      "Consider boosting potassium in your diet.",
    ]) {
      assert.equal(screenResponse(text).safe, false, text);
    }
  });

  /** Nearly all salt substitutes are potassium chloride. */
  test("salt substitutes and supplements are blocked", () => {
    for (const text of [
      "Consider a salt substitute instead of table salt.",
      "LoSalt is a good swap.",
      "A potassium supplement could help.",
      "Try potassium chloride in place of salt.",
    ]) {
      assert.equal(screenResponse(text).safe, false, text);
    }
  });

  /** Explaining it, with the caveat, is exactly what should be allowed. */
  test("explaining potassium with a doctor caveat is allowed", () => {
    const text =
      "Potassium affects blood pressure, but check with your doctor before " +
      "changing your intake — it can be unsafe with some kidney conditions and medicines.";
    assert.equal(screenResponse(text).safe, true);
  });

  test("ordinary sodium and diet advice is unaffected", () => {
    for (const text of [
      "Your sodium was 3100mg yesterday, about double your usual.",
      "The DASH pattern emphasises vegetables, wholegrains and lean protein.",
      "Aim for under 2300mg of sodium a day.",
      "Most sodium comes from processed food rather than the salt cellar.",
    ]) {
      assert.equal(screenResponse(text).safe, true, text);
    }
  });
});

describe("after a doctor's visit", () => {
  /**
   * Endorsing a prescription is as far outside the coach's competence as
   * questioning one. It has neither the examination nor the reasoning behind the
   * decision, and "that dose seems high" from an app is how someone stops taking
   * something they were told to take.
   */
  test("second-guessing a prescriber is blocked", () => {
    for (const text of [
      "That dose seems high for someone your age.",
      "This medication sounds unusual given your readings.",
      "That change looks aggressive.",
      "Your doctor should have prescribed something else.",
      "Your doctor may be wrong about that.",
    ]) {
      assert.equal(screenResponse(text).safe, false, text);
    }
  });

  /** Agreeing is blocked too — it is the same claim of competence. */
  test("endorsing a prescriber is blocked as well", () => {
    for (const text of [
      "That dose seems appropriate.",
      "This prescription is reasonable.",
      "Your doctor was right to increase it.",
    ]) {
      assert.equal(screenResponse(text).safe, false, text);
    }
  });

  test("asking what changed, and helping record it, is allowed", () => {
    for (const text of [
      "Did anything change at your appointment — a new medicine, or a different dose?",
      "You can record the new dose under Add, Medicine Reminder.",
      "Amlodipine is a calcium channel blocker. Your pharmacist can tell you more.",
      "That is worth raising with your doctor directly — I can help you prepare what to ask.",
    ]) {
      assert.equal(screenResponse(text).safe, true, text);
    }
  });

  test("the prompt tells the coach to ask about changes and not to judge them", () => {
    assert.match(SYSTEM_PROMPT, /whether anything changed/i);
    assert.match(SYSTEM_PROMPT, /Do not evaluate what the doctor decided/i);
  });
});

describe("coach actions", () => {
  const future = () => new Date(Date.now() + 20 * 86400000).toISOString();
  const block = (obj) => "I'll set that up.\n\n```action\n" + JSON.stringify(obj) + "\n```";

  test("a well-formed appointment is proposed", () => {
    const { text, action } = extractAction(
      block({ kind: "addAppointment", doctorName: "Dr Sharma", scheduledFor: future() })
    );
    assert.equal(action.kind, "addAppointment");
    assert.equal(action.doctorName, "Dr Sharma");
    assert.equal(text, "I'll set that up.");
  });

  /**
   * The most important test here. A medication reminder built from a guessed
   * dose tells someone to take the wrong amount at 8am, and they will trust the
   * reminder over their memory of a chat.
   */
  test("a medication without a dose is rejected outright", () => {
    const { action } = extractAction(
      block({ kind: "addMedication", name: "Amlodipine", frequency: "onceDaily" })
    );
    assert.equal(action, null);
  });

  test("a complete medication is proposed", () => {
    const { action } = extractAction(
      block({ kind: "addMedication", name: "Amlodipine", dose: "5mg",
              frequency: "onceDaily", reminderTimes: [480] })
    );
    assert.equal(action.dose, "5mg");
    assert.deepEqual(action.reminderTimes, [480]);
  });

  test("an appointment in the past is rejected", () => {
    const { action } = extractAction(
      block({ kind: "addAppointment", doctorName: "Dr X", scheduledFor: "2020-01-01T10:00:00Z" })
    );
    assert.equal(action, null);
  });

  /** A date two years out is almost always a misread year. */
  test("an implausibly distant appointment is rejected", () => {
    const far = new Date(Date.now() + 900 * 86400000).toISOString();
    const { action } = extractAction(
      block({ kind: "addAppointment", doctorName: "Dr X", scheduledFor: far })
    );
    assert.equal(action, null);
  });

  test("an impossible reading is rejected", () => {
    for (const r of [
      { systolic: 80, diastolic: 120 },
      { systolic: 400, diastolic: 90 },
      { systolic: 40, diastolic: 20 },
    ]) {
      const { action } = extractAction(block({ kind: "addReading", ...r }));
      assert.equal(action, null, JSON.stringify(r));
    }
  });

  test("a future-dated reading is rejected", () => {
    const { action } = extractAction(
      block({ kind: "addReading", systolic: 120, diastolic: 80, recordedAt: future() })
    );
    assert.equal(action, null);
  });

  test("an unknown symptom is rejected", () => {
    const { action } = extractAction(
      block({ kind: "addSymptom", symptom: "spontaneous combustion", severity: "mild" })
    );
    assert.equal(action, null);
  });

  test("an unknown action kind is rejected", () => {
    const { action } = extractAction(block({ kind: "deleteAllData" }));
    assert.equal(action, null);
  });

  /** A reply with no action, or a broken one, must still deliver its text. */
  test("the text reply survives a missing or broken action", () => {
    assert.equal(extractAction("Just a reply.").action, null);
    assert.equal(extractAction("Just a reply.").text, "Just a reply.");

    const broken = extractAction("Here you go.\n```action\n{not json}\n```");
    assert.equal(broken.action, null);
    assert.equal(broken.text, "Here you go.");
  });

  test("the prompt forbids inventing a dose and claiming it is saved", () => {
    assert.match(SYSTEM_PROMPT, /Never invent a detail/i);
    assert.match(SYSTEM_PROMPT, /Nothing is saved until they confirm/i);
  });
});
