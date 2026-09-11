#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared end-to-end steps for the three pairing scripts. Do not run this file.
# Use:
#   ./scripts/test-openclaw-ollama.sh
#   ./scripts/test-hermes-nim.sh
#   ./scripts/test-deepagents-vllm.sh
#
# Caller must export AGENT_NAME, INFERENCE_RUNTIME, and INFERENCE_MODEL first.
# RUN_LOAD_TEST defaults to 0 (install inference, skip HPA scale-up/down).
# Set RUN_LOAD_TEST=1 later to also run hpa-load-test.sh.
#
# SECURITY: this path does NOT default to an insecure configuration. See the
# ALLOW_INSECURE_HTTP / ALLOW_UNAUTHENTICATED_OPENSHELL block below — you must
# explicitly opt in before it will run at all.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: do not run e2e-common.sh. Use ./scripts/test-openclaw-ollama.sh, ./scripts/test-hermes-nim.sh, or ./scripts/test-deepagents-vllm.sh." >&2
  exit 1
fi

# ============================================================================
# Optional overrides (pairing scripts already pinned agent/runtime/model)
# ============================================================================
REGISTRY="${REGISTRY:-localhost:32000}"          # registry every cluster node can pull from
                                                  # (MicroK8s local registry default)

# NIM only — get a key from https://ngc.nvidia.com (Setup > API Keys). This one key
# authenticates both the nvcr.io image pull (imagePullSecret, auto-created) and the
# in-container model profile download (NGC_API_KEY) — see ../README.md#nvidia-nim-registry-access.
# export NIM_NGC_API_KEY=nvapi-...

# Optional: pin everything to one GPU node (required on a shared cluster).
# This host uses dgx01 via gitignored local.env; override only if you mean it.
# export NEMOCLAW_TARGET_NODE=dgx01

# 0 = install GPU inference only (no synthetic scale-up). 1 = also run hpa-load-test.sh.
RUN_LOAD_TEST="${RUN_LOAD_TEST:-0}"

# SECURITY (required — no default): this shortcut does not silently enable an insecure
# configuration for you. It has exactly two supported modes:
#
#   1. Isolated/dedicated eval cluster (no other tenants, port-forward only, never
#      exposed externally) — explicitly acknowledge cleartext HTTP + unauthenticated
#      OpenShell for a fast test by exporting all three of:
#        export ALLOW_INSECURE_HTTP=1
#        export ALLOW_UNAUTHENTICATED_OPENSHELL=1
#        export OPENSHELL_UNAUTHENTICATED_ACK=dedicated-cluster-port-forward-only
#
#   2. Shared/production cluster — leave all three unset (the default) and instead
#      configure ingress.tls + OPENSHELL_OIDC_ISSUER before running; see
#      ../README.md#tls-values. This shortcut has no flags for your certificates or OIDC
#      issuer, so ./scripts/install-hpa.sh / ./scripts/install-openshell-k8s.sh below will
#      fail fast with instructions if those aren't configured — that failure is intentional,
#      not a bug, and follows the recipe's normal secure-by-default scripts.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${CHART_DIR}"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"
hpa_common_load_local_env "${CHART_DIR}"
if [[ -n "${NEMOCLAW_TARGET_NODE:-}" ]]; then
  echo "GPU node pin: NEMOCLAW_TARGET_NODE=${NEMOCLAW_TARGET_NODE} (inference and sandboxes stay on this node)"
else
  echo "WARNING: NEMOCLAW_TARGET_NODE is unset; GPU pods may schedule on any GPU node." >&2
fi
NAMESPACE="${NAMESPACE:-nemoclaw-gpu}"
DCGM_NAMESPACE="${DCGM_NAMESPACE:-gpu-operator-resources}"
# shellcheck source=versions.env
source versions.env
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"

: "${AGENT_NAME:?pairing script must export AGENT_NAME}"
: "${INFERENCE_RUNTIME:?pairing script must export INFERENCE_RUNTIME}"

agent_common_validate "${AGENT_NAME}"
agent_common_validate_inference_runtime "${INFERENCE_RUNTIME}"
agent_common_validate_runtime_pairing "${AGENT_NAME}" "${INFERENCE_RUNTIME}"
INFERENCE_MODEL="${INFERENCE_MODEL:-$(agent_common_default_inference_model "${INFERENCE_RUNTIME}")}"
if [[ "${INFERENCE_RUNTIME}" == "nim" ]]; then
  hpa_common_require_nim_credentials "${INFERENCE_RUNTIME}" "${NAMESPACE}" || exit 1
fi
export AGENT_NAME INFERENCE_RUNTIME INFERENCE_MODEL

case "${RUN_LOAD_TEST}" in
  0 | 1) ;;
  *)
    echo "ERROR: RUN_LOAD_TEST must be 0 or 1 (got '${RUN_LOAD_TEST}')." >&2
    exit 1
    ;;
esac

# Transparency, not enforcement: install-hpa.sh / install-openshell-k8s.sh below are the
# ones that actually validate and enforce these — this just states the mode up front so
# it's never a silent surprise which path you're on.
if [[ "${ALLOW_INSECURE_HTTP:-0}" == "1" || "${ALLOW_UNAUTHENTICATED_OPENSHELL:-0}" == "1" ]]; then
  echo "Security mode: ISOLATED-EVAL SHORTCUT (cleartext HTTP and/or unauthenticated OpenShell requested via env vars)." >&2
else
  echo "Security mode: SECURE (default) — TLS + OIDC required; the install steps below will fail fast with setup instructions if ingress.tls / OPENSHELL_OIDC_ISSUER aren't configured. See ../README.md#tls-values, or opt into the isolated-eval shortcut (see the SECURITY comment at the top of this file)." >&2
fi

echo "=== 1/7: GPU + DCGM sanity check ==="
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" GPUs="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
kubectl get pods -n "${DCGM_NAMESPACE}" -l app=nvidia-dcgm-exporter

echo "=== 2/7: Install GPU inference (${INFERENCE_RUNTIME}) ==="
if [[ "${SKIP_INSTALL_HPA:-0}" == "1" ]]; then
  echo "SKIP_INSTALL_HPA=1: leaving existing ${RELEASE} in ${NAMESPACE} unchanged."
else
  ./scripts/install-hpa.sh
fi
kubectl get pods,service,hpa -n "${NAMESPACE}"
./scripts/get-hpa.sh -n "${NAMESPACE}"

if [[ "${RUN_LOAD_TEST}" == "1" ]]; then
  echo "=== 3/7: Synthetic HPA load test (scale-up -> Envoy LeastRequest check -> scale-down) ==="
  ./scripts/hpa-load-test.sh
else
  echo "=== 3/7: Synthetic HPA load test skipped (RUN_LOAD_TEST=0; pairing check only) ==="
fi

echo "=== 4/7: Agent Sandbox CRDs + build ${AGENT_NAME} sandbox image ==="
kubectl apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
microk8s enable registry 2>/dev/null || true   # no-op if already on / not MicroK8s
AGENT_SANDBOX_IMAGE="${AGENT_SANDBOX_IMAGE:-${REGISTRY}/nemoclaw-${AGENT_NAME}-k8s:${NEMOCLAW_VERSION}}"
export AGENT_SANDBOX_IMAGE
./scripts/build-agent-sandbox-image.sh

echo "=== 5/7: Install OpenShell gateway ==="
./scripts/install-openshell-k8s.sh

echo "=== 6/7: Port-forward + connect OpenShell CLI (no second terminal needed) ==="
PF_LOG="$(mktemp)"
AGENT_RUNTIME_LOG=""
AGENT_RUNTIME_PID=""
kubectl -n nemoclaw-sandboxes port-forward service/openshell 8080:8080 >"${PF_LOG}" 2>&1 &
PF_PID=$!
cleanup() {
  if [[ -n "${AGENT_RUNTIME_PID}" ]]; then
    kill "${AGENT_RUNTIME_PID}" 2>/dev/null || true
    wait "${AGENT_RUNTIME_PID}" 2>/dev/null || true
  fi
  kill "${PF_PID}" 2>/dev/null || true
  rm -f "${PF_LOG}"
  [[ -z "${AGENT_RUNTIME_LOG}" ]] || rm -f "${AGENT_RUNTIME_LOG}"
}
trap cleanup EXIT INT TERM

echo "Waiting for the OpenShell gateway port-forward to come up..."
for _ in $(seq 1 30); do
  kill -0 "${PF_PID}" 2>/dev/null || { echo "ERROR: port-forward exited early; see below:" >&2; cat "${PF_LOG}" >&2; exit 1; }
  (exec 3<>"/dev/tcp/127.0.0.1/8080") 2>/dev/null && exec 3>&- 3<&- && break
  sleep 1
done

MTLS_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/openshell/gateways/nemoclaw-k8s/mtls"
if [[ -f "${MTLS_DIR}/tls.key" ]] && openshell status >/dev/null 2>&1; then
  echo "OpenShell gateway nemoclaw-k8s is already registered and reachable."
else
  mkdir -p "${MTLS_DIR}"
  for key in ca.crt tls.crt tls.key; do
    kubectl get secret openshell-client-tls -n nemoclaw-sandboxes \
      -o "jsonpath={.data.${key//./\\.}}" | base64 -d >"${MTLS_DIR}/${key}"
  done
  chmod 600 "${MTLS_DIR}"/*
  openshell gateway add https://127.0.0.1:8080 --local --name nemoclaw-k8s
fi
openshell status

echo "=== 7/7: Create, start, and verify ${AGENT_NAME} sandbox ==="
./scripts/create-agent-sandbox.sh

if [[ "$(agent_common_run_mode "${AGENT_NAME}")" == "terminal" ]]; then
  ./scripts/verify-agent-sandbox.sh
  echo "${AGENT_NAME} verification complete. Run more prompts with:"
  echo "  AGENT_NAME=${AGENT_NAME} ./scripts/run-agent-prompt.sh \"your prompt here\""
else
  AGENT_RUNTIME_LOG="$(mktemp)"
  ./scripts/run-agent-sandbox.sh >"${AGENT_RUNTIME_LOG}" 2>&1 &
  AGENT_RUNTIME_PID=$!
  if ! ./scripts/verify-agent-sandbox.sh; then
    echo "ERROR: ${AGENT_NAME} verification failed; runtime log follows:" >&2
    tail -n 100 "${AGENT_RUNTIME_LOG}" >&2 || true
    exit 1
  fi
  echo "${AGENT_NAME} gateway verified and running — Ctrl+C to stop."
  wait "${AGENT_RUNTIME_PID}"
fi
