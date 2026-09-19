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
| `install-hpa.sh` | Monitoring + chart + HPA (+ Envoy if enabled). This is the autoscaling install path. |
| `hpa-load-test-dgx-8xh100.sh` | HPA load test for **8× H100** on-prem (metrics-proxy pod-IP Job) |
| `hpa-load-test-brev-4xl40s.sh` | HPA load test for **4× L40S** on AWS (Brev) |
| `test-openclaw-e2e-hpa.sh` | N OpenClaw sandboxes (default `E2E_USERS=10`) as the 8×H100 saturator (`inference.local` → Envoy → GPU HPA) |
| `setup-openclaw-e2e-sandboxes.sh` | Create / start / stop / cleanup `openclaw-e2e-*` sandboxes for that e2e |
| `e2e-openclaw-load-test.py` | Per-user driver used by `test-openclaw-e2e-hpa.sh` (`openclaw agent`) |
| `test-hermes-e2e-hpa.sh` | Same N-user e2e for Hermes (`hermes -z`); do not run while OpenClaw e2e owns the GPUs |
| `setup-hermes-e2e-sandboxes.sh` | Create / start / stop / cleanup `hermes-e2e-*` only |
| `e2e-hermes-load-test.py` | Per-user driver used by `test-hermes-e2e-hpa.sh` |
| `hpa-reset.sh` | Restore idle HPA / inference |
| `cluster-recover.sh` | Destructive release recovery for the selected release only — see script comments before use |
| `get-metrics-proxy-pods.sh` / `get-hpa.sh` / `hpa-watch.sh` | Inspect / watch |
| `install-openshell-k8s.sh` | OpenShell gateway |
| `build-agent-sandbox-image.sh` / `create-agent-sandbox.sh` / `verify-agent-sandbox.sh` / `run-agent-sandbox.sh` / `run-agent-prompt.sh` | Agent sandbox lifecycle — pick the agent (`openclaw`, `hermes`, or `deepagents`, mirroring [`NVIDIA/NemoClaw/agents`](https://github.com/NVIDIA/NemoClaw/tree/main/agents)) via a single `AGENT_NAME` flag; see [`../AGENT-SELECTION.md`](../AGENT-SELECTION.md) |
| `agent-common.sh` | Per-agent config table sourced by the scripts above |
| `test-openclaw-ollama.sh` | Optional developer test: OpenClaw + Ollama, one replica, no HPA, no load test. Not required for autoscaling. |
| `test-hermes-nim.sh` | Optional developer test: Hermes + NIM, one replica, no HPA, no load test (needs NGC Secrets). Not required for autoscaling. |
| `test-deepagents-vllm.sh` | Optional developer test: Deep Agents Code + vLLM, one replica, no HPA, no load test. Not required for autoscaling. |
| `e2e-common.sh` | Shared steps sourced by those three optional pairing tests — do not run it directly |
