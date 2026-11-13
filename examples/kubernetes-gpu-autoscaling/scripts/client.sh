#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Step 6d load client. Starts OpenClaw, Hermes, and Deep Agents together.
# GPU utilization and latency use this same script. Per-pairing wrappers
# remain for 6a/6b/6c.
#
#   ./scripts/client.sh gpu_utilization
#   ./scripts/client.sh latency_avg
#   ./scripts/client.sh
#
# A metric argument switches every GPU-chart HPA first so the three
# pairings are not mixed. With no argument, all three HPAs must already
# share one metric.
#
# Env: NEMOCLAW_V1_STATE_DIR (default .local/gpu-autoscaling-mixed),
# V1_NAMESPACE (default nemoclaw-v1-agents), GPU_NAMESPACE
# (default nemoclaw-gpu), E2E_USERS (users per pairing, default 3),
# E2E_OUTPUT_DIR, DURATION_SEC.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

NAMED_METRIC=""
if (($# >= 1)); then
  case "${1}" in
    gpu_utilization | latency_avg)
      NAMED_METRIC="${1}"
      shift
      ;;
    *)
      echo "Usage: $0 [gpu_utilization|latency_avg]" >&2
      exit 2
      ;;
  esac
fi
(($# == 0)) || fail "unexpected arguments: $*"

# Pairing-specific flags must not inherit a leftover single-client run.
unset NAMESPACE RELEASE HPA_NAME V1_AGENT_KIND INFERENCE_RUNTIME INFLIGHT MAX_TOKENS

export NEMOCLAW_V1_STATE_DIR="${NEMOCLAW_V1_STATE_DIR:-${RECIPE_DIR}/.local/gpu-autoscaling-mixed}"
export V1_NAMESPACE="${V1_NAMESPACE:-nemoclaw-v1-agents}"
GPU_NAMESPACE="${GPU_NAMESPACE:-nemoclaw-gpu}"
USERS_PER_PAIRING="${E2E_USERS:-3}"
[[ "${USERS_PER_PAIRING}" =~ ^[1-9][0-9]*$ ]] || fail "E2E_USERS must be a positive integer"
OUT_ROOT="${E2E_OUTPUT_DIR:-${RECIPE_DIR}/e2e-results/mixed}"

hpa_mode() {
  local hpa="${1:?hpa}"
  kubectl get hpa "${hpa}" -n "${GPU_NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.nemoclaw\.ai/hpa-mode}' \
    2>/dev/null || true
}

METRIC="${NAMED_METRIC:-${HPA_METRIC:-}}"
if [[ -z "${NAMED_METRIC}" ]]; then
  if [[ -n "${MIXED_CLIENT_DRY_RUN:-}" ]]; then
    [[ -n "${METRIC}" ]] || fail "set HPA_METRIC or pass gpu_utilization|latency_avg"
  else
    command -v kubectl >/dev/null 2>&1 || fail "missing command: kubectl"
    ollama_mode="$(hpa_mode openclaw-ollama)"
    vllm_mode="$(hpa_mode hermes-vllm)"
    nim_mode="$(hpa_mode deepagents-nim)"
    [[ -n "${ollama_mode}" && "${ollama_mode}" == "${vllm_mode}" && "${vllm_mode}" == "${nim_mode}" ]] \
      || fail "OpenClaw, Hermes, and Deep Agents HPAs must use the same metric (got ${ollama_mode:-missing}, ${vllm_mode:-missing}, ${nim_mode:-missing}). Pass gpu_utilization or latency_avg."
    if [[ -n "${METRIC}" && "${METRIC}" != "${ollama_mode}" ]]; then
      fail "HPA_METRIC=${METRIC} but live HPAs are ${ollama_mode}"
    fi
    METRIC="${ollama_mode}"
  fi
fi
case "${METRIC}" in
  gpu_utilization | latency_avg) ;;
  *) fail "unsupported HPA metric ${METRIC}" ;;
esac
export HPA_METRIC="${METRIC}"

if [[ -n "${NAMED_METRIC}" && -z "${MIXED_CLIENT_DRY_RUN:-}" && "${SWITCH_HPA_METRIC:-1}" != "0" ]]; then
  NAMESPACE="${GPU_NAMESPACE}" RELEASE=nemoclaw-gpu-ollama \
    "${SCRIPT_DIR}/set-hpa-metric.sh" "${METRIC}"
  NAMESPACE="${GPU_NAMESPACE}" RELEASE=nemoclaw-gpu-vllm \
    "${SCRIPT_DIR}/set-hpa-metric.sh" "${METRIC}"
  NAMESPACE="${GPU_NAMESPACE}" RELEASE=nemoclaw-gpu-nim \
    "${SCRIPT_DIR}/set-hpa-metric.sh" "${METRIC}"
fi

pids=()

run_pairing() {
  local kind="${1:?kind}"
  shift
  local -a env_pairs=("$@")
  if [[ -n "${MIXED_CLIENT_DRY_RUN:-}" ]]; then
    printf '%s' "${kind}"
    local pair
    for pair in "${env_pairs[@]}"; do
      printf ' %s' "${pair}"
    done
    printf '\n'
    return 0
  fi
  env "${env_pairs[@]}" "${SCRIPT_DIR}/client-${kind}.sh" \
    > >(sed -u "s/^/[${kind}] /") 2>&1 &
  pids+=("$!")
}

shared=(
  "NEMOCLAW_V1_STATE_DIR=${NEMOCLAW_V1_STATE_DIR}"
  "V1_NAMESPACE=${V1_NAMESPACE}"
  "E2E_USERS=${USERS_PER_PAIRING}"
  "HPA_METRIC=${METRIC}"
)

gpu_flags() {
  case "${1}" in
    openclaw) printf '%s\n' INFLIGHT=4 MAX_TOKENS=2048 ;;
    hermes) printf '%s\n' INFLIGHT=2 MAX_TOKENS=1024 ;;
    deepagents) printf '%s\n' INFLIGHT=3 ;;
  esac
}

start_one() {
  local kind="${1:?kind}"
  local ns="${2:?namespace}"
  local hpa="${3:?hpa}"
  local offset="${4:?offset}"
  local -a extra=()
  if [[ "${METRIC}" == gpu_utilization ]]; then
    mapfile -t extra < <(gpu_flags "${kind}")
  fi
  run_pairing "${kind}" \
    "${shared[@]}" \
    "NAMESPACE=${ns}" \
    "HPA_NAME=${hpa}" \
    "E2E_USER_OFFSET=${offset}" \
    "E2E_OUTPUT_DIR=${OUT_ROOT}/${kind}" \
    "${extra[@]+"${extra[@]}"}"
}

start_one openclaw "${GPU_NAMESPACE}" openclaw-ollama 0
start_one hermes "${GPU_NAMESPACE}" hermes-vllm "${USERS_PER_PAIRING}"
start_one deepagents "${GPU_NAMESPACE}" deepagents-nim "$((USERS_PER_PAIRING * 2))"

if [[ -n "${MIXED_CLIENT_DRY_RUN:-}" ]]; then
  exit 0
fi

status=0
for pid in "${pids[@]}"; do
  wait "${pid}" || status=1
done
exit "${status}"
