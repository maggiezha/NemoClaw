#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// The metrics-proxy must read completion_tokens from the upstream chat body
// and export tokens/sec on /metrics. That path is how get-hpa.sh shows TOK/S.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import http from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.resolve(scriptDir, "../files/metrics-proxy-server.ts");
const model = "test-model:1";
const apiKey = "test-only-inference-key";

const backend = http.createServer((req, res) => {
  if (req.url === "/api/tags") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ models: [{ name: model }] }));
    return;
  }
  if (req.url === "/v1/chat/completions" && req.method === "POST") {
    setTimeout(() => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          id: "test-completion",
          choices: [{ message: { role: "assistant", content: "hello" } }],
          usage: { prompt_tokens: 4, completion_tokens: 40, total_tokens: 44 },
        }),
      );
    }, 200);
    return;
  }
  res.writeHead(404);
  res.end();
});

backend.listen(0, "127.0.0.1");
await once(backend, "listening");
const backendAddress = backend.address();
assert.equal(typeof backendAddress, "object");
assert.ok(backendAddress);
const backendPort = (backendAddress as AddressInfo).port;

const child = spawn(process.execPath, [serverPath], {
  env: {
    ...process.env,
    PORT: "0",
    INFERENCE_MODEL: model,
    INFERENCE_API_KEY: apiKey,
    INFERENCE_AUTH_REQUIRED: "true",
    INFERENCE_BASE_URL: `http://127.0.0.1:${backendPort}/v1`,
    INFERENCE_RUNTIME: "ollama",
    INFERENCE_RUNTIME_BASE_URL: `http://127.0.0.1:${backendPort}`,
  },
  stdio: ["ignore", "pipe", "pipe"],
});

let stderr = "";
child.stderr.on("data", (chunk: Buffer) => {
  stderr += chunk.toString();
});

try {
  const listeningPort = await new Promise<number>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`metrics-proxy startup timeout: ${stderr}`)), 10_000);
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`metrics-proxy exited before startup (${code}): ${stderr}`));
    });
    child.stdout?.on("data", (chunk: Buffer) => {
      const match = chunk.toString().match(/listening on :(\d+)/u);
      if (!match) return;
      clearTimeout(timer);
      resolve(Number(match[1]));
    });
  });
  const baseUrl = `http://127.0.0.1:${listeningPort}`;
  const chatResponse = await fetch(`${baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "ignored", messages: [{ role: "user", content: "hi" }] }),
  });
  assert.equal(chatResponse.status, 200);
  await delay(20);
  const metrics = await (await fetch(`${baseUrl}/metrics`)).text();
  const match = metrics.match(/^nemoclaw_llm_tokens_per_second (\d+)/m);
  assert.ok(match, `missing tokens/sec gauge in:\n${metrics}`);
  const tokensPerSec = Number(match[1]);
  assert.ok(
    tokensPerSec >= 50 && tokensPerSec <= 400,
    `tokens/sec ${tokensPerSec} is not the 40 tokens / ~200ms chat (expected ~200)`,
  );
  console.log("OK: chat completions export tokens/sec from upstream usage");
} finally {
  child.kill("SIGTERM");
  backend.close();
  await Promise.allSettled([once(child, "exit"), once(backend, "close")]);
}
