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
            "namespace": "nemoclaw-gpu",
            "name": "nemoclaw-gpu-vllm-metrics-proxy",
            "targets": "0%/40%",
            "minReplicas": 1,
            "maxReplicas": 8,
            "replicas": 1,
            "age": "16h",
            "metric_kind": "gpu_utilization",
            "gpu_util": "0%",
            "latency": "1455",
            "tokens_per_sec": "80/s",
        },
        {
            "namespace": "nemoclaw-gpu",
            "name": "nemoclaw-gpu-ollama-metrics-proxy",
            "targets": "0%/40%",
            "minReplicas": 1,
            "maxReplicas": 8,
            "replicas": 1,
            "age": "16h",
            "metric_kind": "gpu_utilization",
            "gpu_util": "0%",
            "latency": "900",
            "tokens_per_sec": "12/s",
        },
    ],
    "pods": [
        {
            "namespace": "nemoclaw-gpu",
            "name": "nemoclaw-gpu-vllm-metrics-proxy-c9c4bcf65-r94hm",
            "ready": "2/2",
            "status": "Running",
            "restarts": 0,
            "gpu_util": "0%",
            "latency": "1455",
            "tokens_per_sec": "80/s",
            "age": "16h",
        },
        {
            "namespace": "nemoclaw-gpu",
            "name": "nemoclaw-gpu-ollama-metrics-proxy-5c5cd5bc5-45jjq",
            "ready": "2/2",
            "status": "Running",
            "restarts": 0,
            "gpu_util": "0%",
            "latency": "900",
            "tokens_per_sec": "12/s",
            "age": "16h",
        },
    ],
    "gpus": [
        {
            "index": "0",
            "node": "dgx-19",
            "namespace": "nemoclaw-gpu",
            "pod": "nemoclaw-gpu-vllm-metrics-proxy-c9c4bcf65-r94hm",
            "util": "0",
        },
        {
            "index": "1",
            "node": "dgx-19",
            "namespace": "nemoclaw-gpu",
            "pod": "nemoclaw-gpu-ollama-metrics-proxy-5c5cd5bc5-45jjq",
            "util": "0",
        },
    ],
}

text = mod.format_cluster(snapshot)
for banned in ("metrics-proxy", "Deployment/", "nemoclaw-gpu-vllm-metrics-proxy"):
    if banned in text:
        raise SystemExit(f"watch still prints {banned!r}:\n{text}")
for needle in (
    "hermes-vllm",
    "openclaw-ollama",
    "hermes-vllm-r94hm",
    "openclaw-ollama-45jjq",
    "GPU 0",
    "GPU 1",
    "TOK/S",
    "LATENCY",
    "GPU UTIL",
    "80/s",
    "12/s",
    "1455",
    "900",
):
    if needle not in text:
        raise SystemExit(f"missing {needle!r} in:\n{text}")
hpa_header = next((ln for ln in text.splitlines() if ln.startswith("HPA")), "")
if "scaling on GPU utilization" not in hpa_header and "GPU utilization (avg per pod)" not in hpa_header:
    raise SystemExit(f"util HPA subtitle must name GPU utilization:\n{text}")
hpa_lines = [ln for ln in text.splitlines() if "hermes-vllm" in ln and "r94hm" not in ln]
if not hpa_lines:
    raise SystemExit(f"HPA row is not hermes-vllm:\n{text}")
if "1455" not in hpa_lines[0] or "80/s" not in hpa_lines[0]:
    raise SystemExit(f"util HPA row must still print latency and TOK/S:\n{hpa_lines[0]}")
if mod.parse_tokens_per_second("# HELP x\nnemoclaw_llm_tokens_per_second 80\n") != "80/s":
    raise SystemExit("parse_tokens_per_second must read the display gauge")
if mod.parse_latency_ms("# HELP x\nnemoclaw_llm_latency_avg_milliseconds 1455\n") != "1455":
    raise SystemExit("parse_latency_ms must read the latency gauge")
proxy_port = mod._metrics_port(
    {
        "spec": {
            "containers": [
                {
                    "name": "metrics-proxy",
                    "ports": [{"name": "http", "containerPort": 8081}],
                }
            ]
        }
    }
)
if proxy_port != "8081":
    raise SystemExit(f"pod proxy must use containerPort, not name http (got {proxy_port!r})")

lat_snapshot = {
    "hpas": [
        {
            "namespace": "nemoclaw-gpu",
            "name": "hermes-vllm",
            "targets": "880/3000",
            "minReplicas": 1,
            "maxReplicas": 8,
            "replicas": 1,
            "age": "16h",
            "metric_kind": "latency",
            "gpu_util": "98%",
            "latency": "880",
            "tokens_per_sec": "40/s",
        }
    ],
    "pods": [
        {
            "namespace": "nemoclaw-gpu",
            "name": "hermes-vllm-r94hm",
            "ready": "2/2",
            "status": "Running",
            "gpu_util": "98%",
            "latency": "880",
            "tokens_per_sec": "40/s",
            "age": "16h",
        }
    ],
    "gpus": [],
}
lat_text = mod.format_cluster(lat_snapshot)
lat_header = next((ln for ln in lat_text.splitlines() if ln.startswith("HPA")), "")
if "latency" not in lat_header.lower():
    raise SystemExit(f"latency HPA subtitle must name latency:\n{lat_text}")
lat_row = next((ln for ln in lat_text.splitlines() if ln.startswith("hermes-vllm ")), "")
for needle in ("880/3000", "98%", "40/s"):
    if needle not in lat_row:
        raise SystemExit(f"latency HPA row must still print util and TOK/S ({needle!r}):\n{lat_text}")
PY

adapter="${SCRIPT_DIR}/../monitoring/prometheus-adapter-gpu-values.yaml"
if grep -E 'seriesQuery:.*tokens_per_second|[[:space:]]as:[[:space:]]+".*tokens_per_second' "${adapter}"; then
  echo "FAIL: prometheus-adapter must not expose tokens/sec as an HPA custom metric" >&2
  exit 1
fi

echo "OK: one watch labels rows hermes-vllm / openclaw-ollama and prints GPU UTIL, LATENCY, TOK/S"
