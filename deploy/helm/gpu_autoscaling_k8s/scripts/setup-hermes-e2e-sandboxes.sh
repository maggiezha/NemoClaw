#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Create, start, stop, or destroy N CPU-only Hermes agent sandboxes (one per
# end user) for the multi-user HPA test. Same layout as
# setup-openclaw-e2e-sandboxes.sh. The model stays on GPU inference pods.
# Traffic: sandbox → inference.local → Envoy → GPU HPA.
#
# Does not run openshell gateway start, nemohermes launch, or the
# metrics-proxy chat-completions Job. Does not destroy sandboxes outside
# SANDBOX_PREFIX (default hermes-e2e-). Does not touch openclaw-e2e-* or
# hermes-onprem.
#
# Usage:
#   cd deploy/helm/gpu_autoscaling_k8s
#   ./scripts/setup-hermes-e2e-sandboxes.sh             # default E2E_USERS=10
#   E2E_USERS=10 ./scripts/setup-hermes-e2e-sandboxes.sh
#   ./scripts/setup-hermes-e2e-sandboxes.sh 10           # same; any positive count
#   ./scripts/setup-hermes-e2e-sandboxes.sh start
#   ./scripts/setup-hermes-e2e-sandboxes.sh stop
#   ./scripts/setup-hermes-e2e-sandboxes.sh cleanup
#
# Do not run this while the OpenClaw e2e owns the GPUs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=versions.env
source "${CHART_DIR}/versions.env"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"
hpa_common_load_local_env "${CHART_DIR}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_cmd openshell
require_cmd kubectl
require_cmd python3

export PATH="${HOME}/.local/bin:${PATH}"

E2E_USERS="${E2E_USERS:-10}"
ACTION="${1:-}"
if [[ -z "${ACTION}" ]]; then
  ACTION="${E2E_USERS}"
fi
export AGENT_NAME="${AGENT_NAME:-hermes}"
[[ "${AGENT_NAME}" == "hermes" ]] \
  || fail "setup-hermes-e2e-sandboxes.sh is Hermes-only (got AGENT_NAME=${AGENT_NAME})"
agent_common_validate "${AGENT_NAME}"
agent_common_validate_runtime_pairing "${AGENT_NAME}" "${INFERENCE_RUNTIME:-vllm}"
AGENT_DISPLAY_NAME="$(agent_common_display_name "${AGENT_NAME}")"
SANDBOX_PREFIX="${SANDBOX_PREFIX:-hermes-e2e-}"
[[ "${SANDBOX_PREFIX}" =~ ^[a-z][a-z0-9-]{0,40}$ ]] \
  || fail "SANDBOX_PREFIX must be a lowercase Kubernetes-style prefix"
[[ "${SANDBOX_PREFIX}" == hermes-e2e-* || "${SANDBOX_PREFIX}" == "hermes-e2e-" ]] \
  || fail "SANDBOX_PREFIX must stay under hermes-e2e- so OpenClaw e2e / hermes-onprem are not destroyed"

export INFERENCE_RUNTIME="${INFERENCE_RUNTIME:-vllm}"
export INFERENCE_MODEL="${INFERENCE_MODEL:-$(agent_common_default_inference_model "${INFERENCE_RUNTIME}")}"
export NAMESPACE="${NAMESPACE:-nemoclaw-gpu}"
export RELEASE="${RELEASE:-nemoclaw-gpu}"
export ENABLE_ENVOY_LB="${ENABLE_ENVOY_LB:-1}"
export INFERENCE_SERVICE="${INFERENCE_SERVICE:-$(RELEASE="${RELEASE}" CHART_NAME=nemoclaw-gpu hpa_common_metrics_proxy_service)}"
# Official complete Hermes image (not *-sandbox-base).
export AGENT_SANDBOX_IMAGE="${AGENT_SANDBOX_IMAGE:-ghcr.io/nvidia/nemoclaw/hermes-sandbox@sha256:28b9578ab9676ef046de37fa6feb9b7b61824b87d77fd08978758bd01c03cb54}"
export AGENT_SANDBOX_CPU="${AGENT_SANDBOX_CPU:-2}"
export AGENT_SANDBOX_MEMORY="${AGENT_SANDBOX_MEMORY:-4Gi}"
export OPENSHELL_PROVIDER_NAME="${OPENSHELL_PROVIDER_NAME:-$(agent_common_default_provider_name "${AGENT_NAME}")}"

STATE_DIR="${E2E_STATE_DIR:-${CHART_DIR}/e2e-results/hermes-gateways}"
mkdir -p "${STATE_DIR}"

sandbox_name() {
  printf '%s%04d' "${SANDBOX_PREFIX}" "${1:?index}"
}

list_prefix_sandboxes() {
  python3 - "${SANDBOX_PREFIX}" <<'PY'
import json, subprocess, sys
prefix = sys.argv[1]
try:
    raw = subprocess.check_output(["openshell", "sandbox", "list", "-o", "json"], text=True)
except subprocess.CalledProcessError:
    raise SystemExit(0)
try:
    items = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit(0)
names = []
if isinstance(items, list):
    for item in items:
        name = item.get("name") if isinstance(item, dict) else item
        if isinstance(name, str) and name.startswith(prefix):
            names.append(name)
elif isinstance(items, dict):
    for item in items.get("sandboxes") or items.get("items") or []:
        name = item.get("name") if isinstance(item, dict) else item
        if isinstance(name, str) and name.startswith(prefix):
            names.append(name)
for name in sorted(names):
    print(name)
PY
}

gateway_health_ok() {
  local name="${1:?sandbox}"
  timeout --foreground 20 openshell sandbox exec -n "${name}" --no-tty -- \
    bash -c 'code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:8642/health 2>/dev/null || true)"; case "${code}" in 200|401) exit 0 ;; esac; exit 1' \
    >/dev/null 2>&1
}

start_one_gateway() {
  local name="${1:?sandbox}"
  local log="${STATE_DIR}/${name}.log"
  local pidfile="${STATE_DIR}/${name}.pid"
  if gateway_health_ok "${name}"; then
    echo "  ${name}: Hermes gateway already healthy"
    return 0
  fi
  if [[ -f "${pidfile}" ]]; then
    local old_pid
    old_pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      echo "  ${name}: waiting for existing nemoclaw-start pid ${old_pid}"
    else
      rm -f "${pidfile}"
    fi
  fi
  if [[ ! -f "${pidfile}" ]]; then
    echo "  ${name}: starting /usr/local/bin/nemoclaw-start"
    openshell sandbox exec -n "${name}" --no-tty -- \
      /usr/local/bin/nemoclaw-start >"${log}" 2>&1 &
    echo $! >"${pidfile}"
  fi
  local i
  for ((i = 1; i <= 90; i += 1)); do
    if gateway_health_ok "${name}"; then
      echo "  ${name}: gateway healthy"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${name} Hermes gateway did not become healthy; see ${log}" >&2
  return 1
}

stop_one_gateway() {
  local name="${1:?sandbox}"
  local pidfile="${STATE_DIR}/${name}.pid"
  if [[ -f "${pidfile}" ]]; then
    local pid
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${pidfile}"
  fi
  echo "  ${name}: gateway start process stopped"
}

count_from_existing() {
  local names max=0 n
  names="$(list_prefix_sandboxes)"
  [[ -n "${names}" ]] || fail "no ${SANDBOX_PREFIX}* sandboxes; run ./scripts/setup-hermes-e2e-sandboxes.sh ${E2E_USERS} first"
  while IFS= read -r n; do
    [[ -z "${n}" ]] && continue
    n="${n#"${SANDBOX_PREFIX}"}"
    n=$((10#${n}))
    if ((n + 1 > max)); then
      max=$((n + 1))
    fi
  done <<<"${names}"
  printf '%s' "${max}"
}

start_gateways() {
  local count="${1:?count}"
  local i name
  echo "Starting Hermes gateways in ${count} sandboxes (${SANDBOX_PREFIX}0000…)"
  echo "  Optional for e2e load: hermes -z does not need :8642."
  for ((i = 0; i < count; i += 1)); do
    name="$(sandbox_name "${i}")"
    openshell sandbox get "${name}" >/dev/null 2>&1 \
      || fail "sandbox ${name} does not exist"
    start_one_gateway "${name}"
  done
}

stop_gateways() {
  local name
  echo "Stopping Hermes gateway start processes for ${SANDBOX_PREFIX}*"
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    stop_one_gateway "${name}"
  done < <(list_prefix_sandboxes)
}

cleanup_sandboxes() {
  local name
  stop_gateways || true
  echo "Destroying sandboxes named ${SANDBOX_PREFIX}* (not hermes-onprem, not openclaw-e2e-*)"
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    echo "  destroying ${name}"
    openshell sandbox destroy "${name}" --force >/dev/null 2>&1 || true
  done < <(list_prefix_sandboxes)
  echo "Cleanup complete."
}

create_sandboxes() {
  local count="${1:?count}"
  local i name created=0
  E2E_USERS="${count}"
  export E2E_USERS
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || fail "sandbox count must be a positive integer"
  ((count <= 200)) || fail "refusing more than 200 sandboxes in one run"
  openshell status >/dev/null \
    || fail "OpenShell gateway is not connected; port-forward service/openshell and re-register the gateway"
  hpa_common_verify_target_node 1 || exit 1
  echo "Creating ${count} CPU-only ${AGENT_DISPLAY_NAME} agent sandboxes (${SANDBOX_PREFIX}0000 …)"
  echo "  Agent: AGENT_NAME=${AGENT_NAME} (sandbox has no GPU; the agent runs here)"
  echo "  GPU inference backend: runtime=${INFERENCE_RUNTIME} model=${INFERENCE_MODEL} ns=${NAMESPACE} release=${RELEASE} ENABLE_ENVOY_LB=${ENABLE_ENVOY_LB}"
  for ((i = 0; i < count; i += 1)); do
    name="$(sandbox_name "${i}")"
    if openshell sandbox get "${name}" >/dev/null 2>&1; then
      echo "  ${name} already exists, skipping create"
      created=$((created + 1))
      continue
    fi
    echo "  creating ${name} (user ${i}, agent ${AGENT_NAME})"
    created_ok=0
    for attempt in 1 2 3 4 5; do
      if AGENT_NAME=hermes AGENT_SANDBOX_NAME="${name}" \
        SKIP_CREATE_SMOKE="$([[ "${i}" -eq 0 && "${attempt}" -eq 1 ]] && echo 0 || echo 1)" \
        "${SCRIPT_DIR}/create-agent-sandbox.sh"; then
        created_ok=1
        break
      fi
      echo "  ${name}: waiting for OpenShell supervisor (attempt ${attempt}/5)"
      sleep 15
      if openshell sandbox get "${name}" >/dev/null 2>&1; then
        echo "  ${name}: Ready, continuing"
        created_ok=1
        break
      fi
    done
    [[ "${created_ok}" -eq 1 ]] || fail "failed to create ${name}"
    created=$((created + 1))
  done
  echo "Ready: ${created}/${count} sandboxes. Optional gateway start:"
  echo "  ./scripts/setup-hermes-e2e-sandboxes.sh start"
  echo "Load path is hermes -z into each sandbox (no Envoy-direct Job)."
}

case "${ACTION}" in
  cleanup)
    cleanup_sandboxes
    ;;
  start)
    start_gateways "${E2E_USERS:-$(count_from_existing)}"
    ;;
  stop)
    stop_gateways
    ;;
  '' | *[!0-9]*)
    fail "usage: $0 <count>|start|stop|cleanup"
    ;;
  *)
    create_sandboxes "${ACTION}"
    ;;
esac
