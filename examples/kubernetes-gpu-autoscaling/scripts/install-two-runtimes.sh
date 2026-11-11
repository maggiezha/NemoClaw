#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Install three copies of this chart: vLLM for Hermes, Ollama for OpenClaw,
# and NIM for Deep Agents. Each Horizontal Pod Autoscaler ceiling is
# MAX_REPLICAS (default 8). The node still has one pool of GPUs. A pod that
# does not fit stays Pending. NIM also needs NGC Secrets in its namespace
# before Helm runs.
#
#   DCGM_NAMESPACE=gpu-operator ./scripts/install-two-runtimes.sh
#   ENABLE_ENVOY_LB=0 skips Envoy; sandboxes use each release's metrics-proxy Service.
#
# Leaves the existing nemoclaw-gpu release in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"

MAX_REPLICAS="${MAX_REPLICAS:-8}"
DCGM_NAMESPACE="${DCGM_NAMESPACE:-gpu-operator}"
VLLM_RELEASE="${VLLM_RELEASE:-nemoclaw-gpu-vllm}"
OLLAMA_RELEASE="${OLLAMA_RELEASE:-nemoclaw-gpu-ollama}"
NIM_RELEASE="${NIM_RELEASE:-nemoclaw-gpu-nim}"

ensure_nim_secrets() {
  local namespace="${1:?namespace}"
  local ngc_secret="${NIM_NGC_API_KEY_SECRET:-nim-ngc-key}"
  local pull_secret="${NIM_IMAGE_PULL_SECRET:-ngc-registry}"
  export NIM_NGC_API_KEY_SECRET="${ngc_secret}"
  export NIM_IMAGE_PULL_SECRET="${pull_secret}"
  if kubectl get secret "${ngc_secret}" -n "${namespace}" >/dev/null 2>&1 \
    && kubectl get secret "${pull_secret}" -n "${namespace}" >/dev/null 2>&1; then
    echo "NIM Secrets ${ngc_secret} and ${pull_secret} already exist in ${namespace}"
    hpa_common_require_nim_credentials nim "${namespace}"
    return
  fi
  if [[ ! -f "${CHART_DIR}/secrets.env" ]]; then
    hpa_common_require_nim_credentials nim "${namespace}"
    return
  fi
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  NAMESPACE="${namespace}" "${SCRIPT_DIR}/apply-local-secrets.sh"
  hpa_common_require_nim_credentials nim "${namespace}"
}

install_one() {
  local release="${1:?release}"
  local runtime="${2:?runtime}"
  local skip_monitoring="${3:?skip}"
  echo "Installing ${release} runtime=${runtime} maxReplicas=${MAX_REPLICAS}"
  RELEASE="${release}" \
    NAMESPACE="${release}" \
    INFERENCE_RUNTIME="${runtime}" \
    MAX_REPLICAS="${MAX_REPLICAS}" \
    HPA_SHARED_GPU_CEILING=1 \
    ENABLE_ENVOY_LB="${ENABLE_ENVOY_LB:-1}" \
    SKIP_MONITORING="${skip_monitoring}" \
    DCGM_NAMESPACE="${DCGM_NAMESPACE}" \
    "${SCRIPT_DIR}/install-hpa.sh"
}

service_url() {
  local release="${1:?release}"
  local service
  service="$(RELEASE="${release}" CHART_NAME=nemoclaw-gpu hpa_common_metrics_proxy_service)"
  printf 'http://%s.%s.svc.cluster.local:8081/v1\n' "${service}" "${release}"
}

ensure_nim_secrets "${NIM_RELEASE}"
install_one "${VLLM_RELEASE}" vllm 0
install_one "${OLLAMA_RELEASE}" ollama 1
install_one "${NIM_RELEASE}" nim 1

echo "Hermes inference: $(service_url "${VLLM_RELEASE}")"
echo "OpenClaw inference: $(service_url "${OLLAMA_RELEASE}")"
echo "Deep Agents inference: $(service_url "${NIM_RELEASE}")"
echo "Each ceiling is maxReplicas=${MAX_REPLICAS}. Idle replicas still hold their GPUs until that runtime scales down."
