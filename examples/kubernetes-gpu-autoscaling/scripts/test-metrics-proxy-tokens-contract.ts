#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Tokens/sec is display-only: the proxy reports GPU decode throughput from
// completed chats. It is not an HPA metric (high-as-busy would scale down when
// replicas split load).

import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

process.env.LLM_LATENCY_IDLE_EXPIRE_MS = "100";
process.env.LLM_LATENCY_WINDOW_MS = "100";

const metricsPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../files/metrics-proxy-metrics.ts");
const {
  recordLlmLatency,
  llmMetricsLines,
  completionTokensFromUpstream,
  setLlmMetricsClockForTests,
  resetLlmLatencyWindowForTests,
} = await import(pathToFileURL(metricsPath).href);

function gaugeValue(lines: string[], name: string): number {
  const prefix = `${name} `;
  const line = lines.find((entry) => entry.startsWith(prefix));
  assert.ok(line, `missing gauge ${name}`);
  return Number(line.slice(prefix.length));
}

let nowMs = 1_000_000;
setLlmMetricsClockForTests(() => nowMs);
resetLlmLatencyWindowForTests();

let lines = llmMetricsLines();
assert.ok(
  !lines.some((entry: string) => entry.startsWith("nemoclaw_llm_tokens_per_second ")),
  "new replica with no samples must omit tokens/sec (0 would look like a ready HPA signal)",
);

recordLlmLatency(1000, true, 100);
lines = llmMetricsLines();
assert.equal(gaugeValue(lines, "nemoclaw_llm_latency_avg_milliseconds"), 1000);
assert.equal(gaugeValue(lines, "nemoclaw_llm_tokens_per_second"), 100);

recordLlmLatency(1000, true, 100);
lines = llmMetricsLines();
assert.equal(gaugeValue(lines, "nemoclaw_llm_tokens_per_second"), 200);

nowMs += 101;
lines = llmMetricsLines();
assert.equal(gaugeValue(lines, "nemoclaw_llm_tokens_per_second"), 0);

assert.equal(
  completionTokensFromUpstream(
    JSON.stringify({
      choices: [{ message: { content: "hello" } }],
      usage: { prompt_tokens: 8, completion_tokens: 42, total_tokens: 50 },
    }),
    "application/json",
  ),
  42,
);
assert.equal(
  completionTokensFromUpstream(
    [
      'data: {"choices":[{"delta":{"content":"hel"}}]}',
      'data: {"choices":[{"delta":{"content":"lo"}}]}',
      'data: {"usage":{"completion_tokens":17}}',
      "data: [DONE]",
    ].join("\n"),
    "text/event-stream",
  ),
  17,
);
assert.equal(
  completionTokensFromUpstream(
    JSON.stringify({ choices: [{ message: { content: "abcd1234" } }] }),
    "application/json",
  ),
  2,
);

setLlmMetricsClockForTests(null);
console.log("OK: tokens/sec gauge follows completed chats and idle-expires");
