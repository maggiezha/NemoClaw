<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Scripts

Setup and load-test steps live in [`../README.md`](../README.md). Pairing files are compared in [`../AGENT-SELECTION.md`](../AGENT-SELECTION.md). This page only names what each script does.

| Script | Purpose |
| --- | --- |
| `check.sh` | Validate the three pairing files and read the cluster. Does not apply. |
| `validate-yaml.py` | Schema check used by `check.sh`. |
| `render-sandboxes.sh` | Print a pairing file expanded to `E2E_USERS` sandboxes. Does not apply. |
| `render-mixed-sandboxes.sh` | Print 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes for step 6d. Does not apply. |
| `install-runtimes.sh` | Install vLLM (`hermes-vllm`), Ollama (`openclaw-ollama`), and NIM (`deepagents-nim`) in namespace `nemoclaw-gpu`, each with ceiling 8. `ENABLE_ENVOY_LB=0` skips Envoy. NIM needs `secrets.env`. |
| `invoke.sh` | One operator prompt through `openshell sandbox exec` after `oidc`. |
| `client.sh` | Mixed load client. Starts OpenClaw, Hermes, and Deep Agents together. `./scripts/client.sh gpu_utilization` or `./scripts/client.sh latency_avg`. Does not print the HPA. |
| `client-openclaw.sh` | OpenClaw client used by `client.sh`. Flags: GPU utilization `INFLIGHT=4 MAX_TOKENS=2048`. Latency omits them. |
| `client-hermes.sh` | Hermes client used by `client.sh`. Flags: GPU utilization `INFLIGHT=2 MAX_TOKENS=1024`. Latency omits them (`INFLIGHT=1 MAX_TOKENS=2048` in the code). |
| `client-deepagents.sh` | Deep Agents client used by `client.sh`. GPU utilization `INFLIGHT=3`. |
| `e2e-fabric-load-test.py` | Per-user driver used by the three clients. |
| `set-hpa-metric.sh` | Switch the chart HPA between `gpu_utilization` and `latency_avg`. |
| `install-hpa.sh` | Monitoring, this chart, HPA, and Envoy when enabled. |
| `apply-local-secrets.sh` | NIM: create `ngc-registry` and `nim-ngc-key` from gitignored `secrets.env`. |
| `create-nim-ngc-secrets.sh` | Implementation used by `apply-local-secrets.sh`. |
| `hpa-load-test-dgx-8xh100.sh` | HPA-only Job for 8× H100. Does not create sandboxes. |
| `hpa-load-test-brev-4xl40s.sh` | Same HPA-only Job for 4× L40S. |
| `hpa-reset.sh` | Restore an idle HPA without deleting the release. |
| `hpa-watch.sh` / `get-hpa.sh` | One terminal for every `nemoclaw-gpu*` HPA, pod, GPU index, GPU UTIL, LATENCY, and TOK/S. `./scripts/get-hpa.sh -w`. Rows are `hermes-vllm` / `openclaw-ollama` / `deepagents-nim`. HPA scales on one metric; the other two columns are display-only. Clients do not run this. |
| `get-metrics-proxy-pods.sh` | Pods only. Prefer `get-hpa.sh -w`. |
| `cluster-recover.sh` | Destructive recovery for the selected release. Read the script before use. |
| `agent-common.sh` / `hpa-common.sh` | Shared settings. Do not run them directly. |
| `e2e_timeline.py` / `e2e-hpa-timeline.py` | Timeline rows written beside a load run. |
| `test-inference-auth-contract.ts` | Metrics-proxy requires the inference API key and rejects non-object chat bodies. |
| `test-metrics-proxy-metrics-contract.ts` | Rolling `latency_avg` uses a 30s window and expires so HPA can scale down. |
| `test-metrics-proxy-tokens-contract.ts` | Display-only `tokens/sec` follows completed chats and idle-expires. Not an HPA metric. |
| `test-metrics-proxy-tokens-http-contract.ts` | Chat completions export `tokens/sec` from upstream `usage.completion_tokens`. |
| `test-metrics-proxy-newest-sample-window.ts` | The 30s window ages from the newest sample. |
| `test-hpa-idle-replicas-contract.sh` | Idle latency HPA `1/0` is a ready baseline. |
| `test-pairing-labels.sh` | Watches and clients print both the agent (`openclaw` / `hermes` / `deepagents`) and the GPU runtime (`ollama` / `vllm` / `nim`). |
| `test-hpa-cluster-watch.sh` | One watch labels rows `hermes-vllm` / `openclaw-ollama`, not `metrics-proxy`, and always prints GPU UTIL, LATENCY, and TOK/S. |
| `test-workload-name.sh` | Helm names the GPU Deployment and HPA `hermes-vllm` / `openclaw-ollama`. |
| `hpa-watch-format.py` | Formats that watch. Do not run it directly. |
| `test-render-mixed-sandboxes.sh` | Step 6d renders 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes on separate Services. |
| `test-state-dir.sh` | Load clients find `terraform.tfstate` in the apply `--state-dir` or its `state/` subdirectory. |
| `test-client.sh` | Step 6d `client.sh` starts OpenClaw, Hermes, and Deep Agents for GPU utilization and latency. |
