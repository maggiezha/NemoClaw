<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Agent selection

The [README quick start](README.md#quick-start) applies OpenClaw, Hermes, and Deep Agents together. Each pairing file in this directory is the template for that harness: a managed OpenShell gateway, Fabric sandboxes, and the GPU chart Service `/v1`. [`render-mixed-sandboxes.sh`](scripts/render-mixed-sandboxes.sh) combines them. Envoy is optional.

| | OpenClaw + Ollama | Hermes + vLLM | Deep Agents + NIM |
| --- | --- | --- | --- |
| File | [`openclaw-ollama.yaml`](openclaw-ollama.yaml) | [`hermes-vllm.yaml`](hermes-vllm.yaml) | [`deepagents-nim.yaml`](deepagents-nim.yaml) |
| `harness.kind` | `nvidia.fabric.openclaw` | `nvidia.fabric.hermes` | `nvidia.fabric.langchain.deepagents` |
| Chart `INFERENCE_RUNTIME` | `ollama` | `vllm` | `nim` |
| GPU Deployment / HPA | `openclaw-ollama` | `hermes-vllm` | `deepagents-nim` |
| Sandboxes in mixed apply | `user-0000`–`user-0002` | `user-0003`–`user-0005` | `user-0006`–`user-0008` |

Agents run in namespace `nemoclaw-v1-agents`. [`install-runtimes.sh`](scripts/install-runtimes.sh) installs Helm releases `nemoclaw-gpu-ollama`, `nemoclaw-gpu-vllm`, and `nemoclaw-gpu-nim` in namespace `nemoclaw-gpu`, each with `maxReplicas` 8. Watch all three with [`get-hpa.sh -w`](scripts/get-hpa.sh). Load all three with [`client.sh`](scripts/client.sh).

GPU utilization and LLM latency use the same client. Switch the chart metric with [`set-hpa-metric.sh`](scripts/set-hpa-metric.sh). Recorded Hermes and Deep Agents runs are in [`RESULTS-6b.md`](RESULTS-6b.md) and [`RESULTS-6c.md`](RESULTS-6c.md).
