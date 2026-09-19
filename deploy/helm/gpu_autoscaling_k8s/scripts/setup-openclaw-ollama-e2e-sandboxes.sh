#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Create, start, stop, or destroy N CPU-only OpenClaw sandboxes (one per end
# user) for the OpenClaw + Ollama HPA e2e. The model stays on Ollama GPU pods
# in nemoclaw-gpu. Traffic: sandbox → inference.local → Envoy → Ollama HPA.
#
# "start" launches one OpenClaw agent (nemoclaw-start) per sandbox. Those are
# agents, not extra OpenShell or Envoy gateways: there is still one OpenShell
# gateway and one Envoy Gateway for the cluster.
#
# Does not run openshell gateway start, nemoclaw launch, or the metrics-proxy
# chat-completions Job (hpa-load-test-*.sh). Keep that Job as the fast HPA-only
# test. Does not destroy sandboxes outside SANDBOX_PREFIX (default
# openclaw-ollama-e2e-). Does not touch hermes-onprem or hermes-e2e-*.
# Hermes + vLLM is a later e2e.
#
# Usage:
#   cd deploy/helm/gpu_autoscaling_k8s
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh          # default E2E_USERS=10
#   E2E_USERS=10 ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh 10
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh start
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh stop
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh cleanup

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
export AGENT_NAME="${AGENT_NAME:-openclaw}"
if [[ "${AGENT_NAME}" != "openclaw" ]]; then
  fail "setup-openclaw-ollama-e2e-sandboxes.sh is OpenClaw + Ollama only (got AGENT_NAME=${AGENT_NAME})"
fi
if [[ -n "${INFERENCE_RUNTIME:-}" && "${INFERENCE_RUNTIME}" != "ollama" ]]; then
  fail "this e2e is OpenClaw + Ollama (got INFERENCE_RUNTIME=${INFERENCE_RUNTIME}). Hermes + vLLM is later and is not started here."
fi
agent_common_pin_example_pairing openclaw ollama
AGENT_DISPLAY_NAME="$(agent_common_display_name "${AGENT_NAME}")"
SANDBOX_PREFIX="${SANDBOX_PREFIX:-openclaw-ollama-e2e-}"
[[ "${SANDBOX_PREFIX}" =~ ^[a-z][a-z0-9-]{0,40}$ ]] \
  || fail "SANDBOX_PREFIX must be a lowercase Kubernetes-style prefix"
[[ "${SANDBOX_PREFIX}" == openclaw-ollama-e2e-* || "${SANDBOX_PREFIX}" == "openclaw-ollama-e2e-" ]] \
  || fail "SANDBOX_PREFIX must stay under openclaw-ollama-e2e- so other agent sandboxes are not destroyed"

export NAMESPACE="${NAMESPACE:-nemoclaw-gpu}"
export RELEASE="${RELEASE:-nemoclaw-gpu}"
if [[ "${NAMESPACE}" != "nemoclaw-gpu" || "${RELEASE}" != "nemoclaw-gpu" ]]; then
  fail "OpenClaw + Ollama e2e uses NAMESPACE=nemoclaw-gpu RELEASE=nemoclaw-gpu (got ${NAMESPACE}/${RELEASE})"
fi
export ENABLE_ENVOY_LB="${ENABLE_ENVOY_LB:-1}"
export INFERENCE_SERVICE="${INFERENCE_SERVICE:-$(RELEASE="${RELEASE}" CHART_NAME=nemoclaw-gpu hpa_common_metrics_proxy_service)}"
if [[ -z "${AGENT_SANDBOX_IMAGE:-}" ]]; then
  case "${AGENT_NAME}" in
    openclaw)
      AGENT_SANDBOX_IMAGE="ghcr.io/nvidia/nemoclaw/openclaw-sandbox@sha256:bd935f0198b99889d9479fea123b62a59e3797da13e392dcc2160f114216c1ba"
      ;;
    *)
      fail "set AGENT_SANDBOX_IMAGE for AGENT_NAME=${AGENT_NAME} (Hermes / Deep Agents e2e reuse this layout later)"
      ;;
  esac
fi
export AGENT_SANDBOX_IMAGE
export AGENT_SANDBOX_CPU="${AGENT_SANDBOX_CPU:-2}"
export AGENT_SANDBOX_MEMORY="${AGENT_SANDBOX_MEMORY:-4Gi}"
export OPENSHELL_PROVIDER_NAME="${OPENSHELL_PROVIDER_NAME:-$(agent_common_default_provider_name "${AGENT_NAME}")}"

STATE_DIR="${E2E_STATE_DIR:-${CHART_DIR}/e2e-results/openclaw-ollama-agents}"
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

agent_health_ok() {
  local name="${1:?sandbox}"
  timeout --foreground 20 openshell sandbox exec -n "${name}" --no-tty -- \
    bash -c 'code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:18789/health 2>/dev/null || true)"; case "${code}" in 200|401) exit 0 ;; esac; exit 1' \
    >/dev/null 2>&1
}

start_one_agent() {
  local name="${1:?sandbox}"
  local log="${STATE_DIR}/${name}.log"
  local pidfile="${STATE_DIR}/${name}.pid"
  if agent_health_ok "${name}"; then
    echo "  ${name}: OpenClaw agent already healthy"
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
    if agent_health_ok "${name}"; then
      echo "  ${name}: OpenClaw agent healthy"
      return 0
    fi
    if [[ "${i}" -eq 1 ]]; then
      echo "  ${name}: waiting for OpenClaw agent on :18789"
    elif [[ $((i % 10)) -eq 0 ]]; then
      echo "  ${name}: still waiting for agent (${i}/90)"
    fi
    sleep 2
  done
  echo "ERROR: ${name} OpenClaw agent did not become healthy; see ${log}" >&2
  return 1
}

stop_one_agent() {
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
  echo "  ${name}: OpenClaw agent start process stopped"
}

count_from_existing() {
  local names max=0 n
  names="$(list_prefix_sandboxes)"
  [[ -n "${names}" ]] || fail "no ${SANDBOX_PREFIX}* sandboxes; run ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh ${E2E_USERS} first"
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

start_agents() {
  local count="${1:?count}"
  local i name
  echo "Starting ${count} OpenClaw agents in ${count} sandboxes (${SANDBOX_PREFIX}0000…). Cluster still has one OpenShell gateway and one Envoy Gateway."
  for ((i = 0; i < count; i += 1)); do
    name="$(sandbox_name "${i}")"
    echo "  sandbox $((i + 1))/${count}: ${name}"
    openshell sandbox get "${name}" >/dev/null 2>&1 \
      || fail "sandbox ${name} does not exist"
    start_one_agent "${name}"
  done
}

stop_agents() {
  local name
  echo "Stopping OpenClaw agent start processes for ${SANDBOX_PREFIX}*"
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    stop_one_agent "${name}"
  done < <(list_prefix_sandboxes)
}

cleanup_sandboxes() {
  local name
  stop_agents || true
  echo "Destroying sandboxes named ${SANDBOX_PREFIX}*"
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
  echo "Creating ${count} CPU-only OpenClaw + Ollama e2e sandboxes (${SANDBOX_PREFIX}0000 …)"
  echo "  Agent: AGENT_NAME=${AGENT_NAME} (sandbox has no GPU; OpenClaw runs here)"
  echo "  GPU inference backend: Ollama model=${INFERENCE_MODEL} ns=${NAMESPACE} release=${RELEASE} ENABLE_ENVOY_LB=${ENABLE_ENVOY_LB}"
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
      if AGENT_SANDBOX_NAME="${name}" \
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
  echo "Ready: ${created}/${count} sandboxes. Start OpenClaw agents with:"
  echo "  ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh start"
}

case "${ACTION}" in
  cleanup)
    cleanup_sandboxes
    ;;
  start)
    start_agents "${E2E_USERS:-$(count_from_existing)}"
    ;;
  stop)
    stop_agents
    ;;
  '' | *[!0-9]*)
    fail "usage: $0 <count>|start|stop|cleanup"
    ;;
  *)
    create_sandboxes "${ACTION}"
    ;;
esac
