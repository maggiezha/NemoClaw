<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Agent selection

Apply one pairing file in this directory. Each file is one NemoClaw config: a managed OpenShell gateway, Fabric sandboxes, and the GPU chart Service `/v1`. The chart and HPA are the Helm release in this directory; Envoy is optional. See the [README quick start](README.md#quick-start).

| | OpenClaw + Ollama | Hermes + vLLM | Deep Agents + NIM |
| --- | --- | --- | --- |
| File | [`openclaw-ollama.yaml`](openclaw-ollama.yaml) | [`hermes-vllm.yaml`](hermes-vllm.yaml) | [`deepagents-nim.yaml`](deepagents-nim.yaml) |
| `harness.kind` | `nvidia.fabric.openclaw` | `nvidia.fabric.hermes` | `nvidia.fabric.langchain.deepagents` |
| Chart `INFERENCE_RUNTIME` | `ollama` | `vllm` | `nim` |
| GPU Deployment / HPA | `openclaw-ollama` | `hermes-vllm` | `deepagents-nim` |
| Namespace | `nemoclaw-v1-gpu-autoscaling-openclaw` | `nemoclaw-v1-gpu-autoscaling` | `nemoclaw-v1-gpu-autoscaling-dagent` |
| State directory | `.local/gpu-autoscaling-openclaw` | `.local/gpu-autoscaling` | `.local/gpu-autoscaling-deepagents` |
| Load client | [`client-openclaw.sh`](scripts/client-openclaw.sh) | [`client-hermes.sh`](scripts/client-hermes.sh) | [`client-deepagents.sh`](scripts/client-deepagents.sh) |

OpenClaw and Deep Agents use their own namespaces, so either can stay up beside the Hermes deployment.

Step 6d keeps OpenClaw, Hermes, and Deep Agents in namespace `nemoclaw-v1-gpu-autoscaling-mixed`. [`install-two-runtimes.sh`](scripts/install-two-runtimes.sh) installs Helm release `nemoclaw-gpu-ollama` (Deployment `openclaw-ollama`), release `nemoclaw-gpu-vllm` (Deployment `hermes-vllm`), and release `nemoclaw-gpu-nim` (Deployment `deepagents-nim`), each with `maxReplicas` 8. Watch all three with [`get-hpa.sh -w`](scripts/get-hpa.sh). [`render-mixed-sandboxes.sh`](scripts/render-mixed-sandboxes.sh) prints 3 OpenClaw sandboxes, 3 Hermes sandboxes, and 3 Deep Agents sandboxes.

GPU utilization and LLM latency use the same client. Switch the chart metric with [`set-hpa-metric.sh`](scripts/set-hpa-metric.sh). Recorded Hermes and Deep Agents runs are in [`RESULTS-6b.md`](RESULTS-6b.md) and [`RESULTS-6c.md`](RESULTS-6c.md).
