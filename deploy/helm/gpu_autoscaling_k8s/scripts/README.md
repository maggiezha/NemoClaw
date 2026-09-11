<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Scripts

All setup, verification, security, and teardown instructions for this recipe live in the
main [`../README.md`](../README.md) (architecture, Quick start, TLS/security details,
inference runtimes, HPA/Envoy testing, Grafana, uninstall) and
[`../AGENT-SELECTION.md`](../AGENT-SELECTION.md) (per-agent comparison, recipe
quick starts, env vars, and support notes). This page is a quick reference for
what each script in this directory does — it has no instructions of its own.

| Script | Purpose |
|--------|---------|
| `test-openclaw-ollama.sh` | One-script path: OpenClaw + Ollama (skips HPA load test unless `RUN_LOAD_TEST=1`) |
| `test-hermes-vllm.sh` | One-script path: Hermes + vLLM (skips HPA load test unless `RUN_LOAD_TEST=1`) |
| `test-deepagents-vllm.sh` | One-script path: Deep Agents Code + vLLM (skips HPA load test unless `RUN_LOAD_TEST=1`) |
| `e2e-common.sh` | Shared steps sourced by those three scripts — do not run it directly |
| `test-agent-runtime-examples-contract.sh` | Static check that each example pairing has a script and README / AGENT-SELECTION links |
| `install-hpa.sh` | Monitoring + chart + HPA (+ Envoy if enabled) |
| `hpa-load-test.sh` / `hpa-reset.sh` | Autoscaling (+ Envoy) test / restore idle |
| `cluster-recover.sh` | Destructive release recovery for the selected release only — see script comments before use |
| `get-metrics-proxy-pods.sh` / `get-hpa.sh` / `hpa-watch.sh` | Inspect / watch |
| `install-openshell-k8s.sh` | OpenShell gateway |
| `build-agent-sandbox-image.sh` / `create-agent-sandbox.sh` / `verify-agent-sandbox.sh` / `run-agent-sandbox.sh` / `run-agent-prompt.sh` | Agent sandbox lifecycle — pick the agent (`openclaw`, `hermes`, or `deepagents`, mirroring [`NVIDIA/NemoClaw/agents`](https://github.com/NVIDIA/NemoClaw/tree/main/agents)) via a single `AGENT_NAME` flag; see [`../AGENT-SELECTION.md`](../AGENT-SELECTION.md) |
| `agent-common.sh` | Per-agent config table sourced by the scripts above |
| `test-*-contract.*` | Static / local contract checks |
