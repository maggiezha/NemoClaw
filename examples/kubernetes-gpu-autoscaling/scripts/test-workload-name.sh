#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# GPU Deployment and HPA names are agent-runtime (hermes-vllm). The Service
# keeps the historical DNS name so mixed sandboxes do not need a re-apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(INFERENCE_RUNTIME=vllm hpa_common_metrics_proxy_deployment)" == "hermes-vllm" ]] \
  || fail "vllm deployment name"
[[ "$(INFERENCE_RUNTIME=ollama hpa_common_metrics_proxy_deployment)" == "openclaw-ollama" ]] \
  || fail "ollama deployment name"
[[ "$(INFERENCE_RUNTIME=nim hpa_common_metrics_proxy_deployment)" == "deepagents-nim" ]] \
  || fail "nim deployment name"
[[ "$(RELEASE=nemoclaw-gpu-vllm hpa_common_metrics_proxy_service)" == "nemoclaw-gpu-vllm-metrics-proxy" ]] \
  || fail "vllm Service DNS stays *-metrics-proxy"

require_cmd helm
require_cmd python3

render() {
  local release="${1:?}"
  local runtime="${2:?}"
  local extra=()
  if [[ "${runtime}" == "nim" ]]; then
    extra+=(--set nim.ngcApiKey.value=test)
  fi
  helm template "${release}" "${CHART_DIR}" \
    --set "namespace.name=${release}" \
    --set namespace.create=false \
    --set "inference.runtime=${runtime}" \
    --set autoscaling.enabled=true \
    --set ingress.gateway.enabled=false \
    "${extra[@]}"
}

check_names() {
  local manifest="${1:?}"
  local want_workload="${2:?}"
  local want_service="${3:?}"
  python3 - "${manifest}" "${want_workload}" "${want_service}" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
want_workload, want_service = sys.argv[2], sys.argv[3]
kind = None
seen_meta_name = False
in_scale = False
got = {"Deployment": [], "HorizontalPodAutoscaler": [], "Service": []}
scale_refs = []
for raw in text.splitlines():
    if raw == "---":
        kind = None
        seen_meta_name = False
        in_scale = False
        continue
    if raw.startswith("kind: "):
        kind = raw.split(":", 1)[1].strip()
        continue
    if raw == "  scaleTargetRef:":
        in_scale = True
        continue
    if in_scale and raw.startswith("    name: "):
        scale_refs.append(raw.split(":", 1)[1].strip())
        in_scale = False
        continue
    if kind in got and not seen_meta_name and raw.startswith("  name: "):
        got[kind].append(raw.split(":", 1)[1].strip())
        seen_meta_name = True

if want_workload not in got["Deployment"]:
    raise SystemExit(f"Deployment names {got['Deployment']!r}, want {want_workload}")
if want_workload not in got["HorizontalPodAutoscaler"]:
    raise SystemExit(f"HPA names {got['HorizontalPodAutoscaler']!r}, want {want_workload}")
if want_service not in got["Service"]:
    raise SystemExit(f"Service names {got['Service']!r}, want {want_service}")
if want_workload not in scale_refs:
    raise SystemExit(f"HPA scaleTargetRef {scale_refs!r}, want {want_workload}")
if any("metrics-proxy" in n for n in got["Deployment"] + got["HorizontalPodAutoscaler"]):
    raise SystemExit(f"Deployment/HPA still use metrics-proxy: {got}")
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

render nemoclaw-gpu-vllm vllm >"${tmp}/vllm.yaml"
check_names "${tmp}/vllm.yaml" hermes-vllm nemoclaw-gpu-vllm-metrics-proxy

render nemoclaw-gpu-ollama ollama >"${tmp}/ollama.yaml"
check_names "${tmp}/ollama.yaml" openclaw-ollama nemoclaw-gpu-ollama-metrics-proxy

render nemoclaw-gpu-nim nim >"${tmp}/nim.yaml"
check_names "${tmp}/nim.yaml" deepagents-nim nemoclaw-gpu-nim-metrics-proxy

echo "OK: GPU pods/HPA are hermes-vllm / openclaw-ollama / deepagents-nim"
