#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One HPA watch labels rows hermes-vllm / openclaw-ollama. It does not print
# metrics-proxy or Deployment/ Kubernetes object names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "${SCRIPT_DIR}/hpa-watch-format.py" <<'PY'
import importlib.util
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("hpa_watch_format", path)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

cases = (
    ("nemoclaw-gpu-vllm-metrics-proxy", "hermes-vllm"),
    ("nemoclaw-gpu-vllm-metrics-proxy-c9c4bcf65-r94hm", "hermes-vllm-r94hm"),
    ("nemoclaw-gpu-ollama-metrics-proxy", "openclaw-ollama"),
    ("nemoclaw-gpu-ollama-metrics-proxy-5c5cd5bc5-45jjq", "openclaw-ollama-45jjq"),
    ("nemoclaw-gpu-nim-metrics-proxy", "deepagents-nim"),
    ("hermes-vllm", "hermes-vllm"),
    ("hermes-vllm-c9c4bcf65-r94hm", "hermes-vllm-r94hm"),
    ("openclaw-ollama-5c5cd5bc5-45jjq", "openclaw-ollama-45jjq"),
)
for name, want in cases:
    got = mod.display_name(name)
    if got != want:
        raise SystemExit(f"{name}: display {got!r}, want {want!r}")

snapshot = {
    "hpas": [
        {
            "namespace": "nemoclaw-gpu-vllm",
            "name": "nemoclaw-gpu-vllm-metrics-proxy",
            "targets": "0%/40%",
            "minReplicas": 1,
            "maxReplicas": 8,
            "replicas": 1,
            "age": "16h",
            "metric_kind": "gpu_utilization",
        },
        {
            "namespace": "nemoclaw-gpu-ollama",
            "name": "nemoclaw-gpu-ollama-metrics-proxy",
            "targets": "0%/40%",
            "minReplicas": 1,
            "maxReplicas": 8,
            "replicas": 1,
            "age": "16h",
            "metric_kind": "gpu_utilization",
        },
    ],
    "pods": [
        {
            "namespace": "nemoclaw-gpu-vllm",
            "name": "nemoclaw-gpu-vllm-metrics-proxy-c9c4bcf65-r94hm",
            "ready": "2/2",
            "status": "Running",
            "restarts": 0,
            "gpu_util": "0%",
            "age": "16h",
        },
        {
            "namespace": "nemoclaw-gpu-ollama",
            "name": "nemoclaw-gpu-ollama-metrics-proxy-5c5cd5bc5-45jjq",
            "ready": "2/2",
            "status": "Running",
            "restarts": 0,
            "gpu_util": "0%",
            "age": "16h",
        },
    ],
    "gpus": [
        {
            "index": "0",
            "node": "dgx-19",
            "namespace": "nemoclaw-gpu-vllm",
            "pod": "nemoclaw-gpu-vllm-metrics-proxy-c9c4bcf65-r94hm",
            "util": "0",
        },
        {
            "index": "1",
            "node": "dgx-19",
            "namespace": "nemoclaw-gpu-ollama",
            "pod": "nemoclaw-gpu-ollama-metrics-proxy-5c5cd5bc5-45jjq",
            "util": "0",
        },
    ],
}

text = mod.format_cluster(snapshot)
for banned in ("metrics-proxy", "Deployment/", "nemoclaw-gpu-vllm-metrics-proxy"):
    if banned in text:
        raise SystemExit(f"watch still prints {banned!r}:\n{text}")
for needle in ("hermes-vllm", "openclaw-ollama", "hermes-vllm-r94hm", "openclaw-ollama-45jjq", "GPU 0", "GPU 1"):
    if needle not in text:
        raise SystemExit(f"missing {needle!r} in:\n{text}")
hpa_lines = [ln for ln in text.splitlines() if "hermes-vllm" in ln and "r94hm" not in ln]
if not hpa_lines:
    raise SystemExit(f"HPA row is not hermes-vllm:\n{text}")
PY

echo "OK: one watch labels rows hermes-vllm / openclaw-ollama"
