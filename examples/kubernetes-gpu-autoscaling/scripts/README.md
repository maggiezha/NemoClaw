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
| `install-two-runtimes.sh` | Install vLLM (`hermes-vllm`), Ollama (`openclaw-ollama`), and NIM (`deepagents-nim`), each with ceiling 8. `ENABLE_ENVOY_LB=0` skips Envoy. NIM needs `secrets.env`. |
| `invoke.sh` | One operator prompt through `openshell sandbox exec` after `oidc`. |
| `client-openclaw.sh` | OpenClaw client. Flags: GPU utilization `INFLIGHT=4 MAX_TOKENS=2048`. Latency omits them. Does not print the HPA. |
| `client-hermes.sh` | Hermes client. Flags: GPU utilization `INFLIGHT=2 MAX_TOKENS=1024`. Latency omits them (`INFLIGHT=1 MAX_TOKENS=2048` in the code). Does not print the HPA. |
| `client-deepagents.sh` | Deep Agents client. GPU utilization `INFLIGHT=3`. Does not print the HPA. |
| `e2e-fabric-load-test.py` | Per-user driver used by the three clients. |
| `set-hpa-metric.sh` | Switch the chart HPA between `gpu_utilization` and `latency_avg`. |
| `install-hpa.sh` | Monitoring, this chart, HPA, and Envoy when enabled. |
| `apply-local-secrets.sh` | NIM: create `ngc-registry` and `nim-ngc-key` from gitignored `secrets.env`. |
| `create-nim-ngc-secrets.sh` | Implementation used by `apply-local-secrets.sh`. |
| `hpa-load-test-dgx-8xh100.sh` | HPA-only Job for 8× H100. Does not create sandboxes. |
| `hpa-load-test-brev-4xl40s.sh` | Same HPA-only Job for 4× L40S. |
| `hpa-reset.sh` | Restore an idle HPA without deleting the release. |
| `hpa-watch.sh` / `get-hpa.sh` | One terminal for every `nemoclaw-gpu*` HPA, pod, and GPU index. `./scripts/get-hpa.sh -w`. Rows are `hermes-vllm` / `openclaw-ollama` / `deepagents-nim`. Clients do not run this. |
| `get-metrics-proxy-pods.sh` | Pods only. Prefer `get-hpa.sh -w`. |
| `cluster-recover.sh` | Destructive recovery for the selected release. Read the script before use. |
| `agent-common.sh` / `hpa-common.sh` | Shared settings. Do not run them directly. |
| `e2e_timeline.py` / `e2e-hpa-timeline.py` | Timeline rows written beside a load run. |
| `test-inference-auth-contract.ts` | Metrics-proxy requires the inference API key and rejects non-object chat bodies. |
| `test-metrics-proxy-metrics-contract.ts` | Rolling `latency_avg` uses a 30s window and expires so HPA can scale down. |
| `test-metrics-proxy-newest-sample-window.ts` | The 30s window ages from the newest sample. |
| `test-hpa-idle-replicas-contract.sh` | Idle latency HPA `1/0` is a ready baseline. |
| `test-pairing-labels.sh` | Watches and clients print both the agent (`openclaw` / `hermes` / `deepagents`) and the GPU runtime (`ollama` / `vllm` / `nim`). |
| `test-hpa-cluster-watch.sh` | One watch labels rows `hermes-vllm` / `openclaw-ollama`, not `metrics-proxy`. |
| `test-workload-name.sh` | Helm names the GPU Deployment and HPA `hermes-vllm` / `openclaw-ollama`. |
| `hpa-watch-format.py` | Formats that watch. Do not run it directly. |
| `test-render-mixed-sandboxes.sh` | Step 6d renders 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes on separate Services. |
