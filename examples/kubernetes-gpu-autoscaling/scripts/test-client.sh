#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Step 6d client.sh starts OpenClaw, Hermes, and Deep Agents together.
# GPU utilization and latency use the same script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -x "${SCRIPT_DIR}/client.sh" ]] || fail "missing executable scripts/client.sh"

unset V1_NAMESPACE GPU_NAMESPACE MIXED_NAME MIXED_UID NEMOCLAW_TARGET_NODE GATEWAY_CONTEXT

gpu="$(MIXED_CLIENT_DRY_RUN=1 HPA_METRIC=gpu_utilization "${SCRIPT_DIR}/client.sh")"
[[ "${gpu}" == *"openclaw"* && "${gpu}" == *"hermes"* && "${gpu}" == *"deepagents"* ]] \
  || fail "GPU util dry-run must start all three pairings"
echo "${gpu}" | grep -q 'openclaw .*NAMESPACE=nemoclaw-gpu HPA_NAME=openclaw-ollama' \
  || fail "OpenClaw GPU util HPA in shared namespace"
echo "${gpu}" | grep -q 'hermes .*NAMESPACE=nemoclaw-gpu HPA_NAME=hermes-vllm' \
  || fail "Hermes GPU util HPA in shared namespace"
echo "${gpu}" | grep -q 'deepagents .*NAMESPACE=nemoclaw-gpu HPA_NAME=deepagents-nim' \
  || fail "Deep Agents GPU util HPA in shared namespace"
echo "${gpu}" | grep -q 'NAMESPACE=nemoclaw-gpu-ollama\|NAMESPACE=nemoclaw-gpu-vllm\|NAMESPACE=nemoclaw-gpu-nim' \
  && fail "6d clients must share namespace nemoclaw-gpu"
echo "${gpu}" | grep -q 'V1_NAMESPACE=nemoclaw-v1-agents' \
  || fail "6d sandboxes use namespace nemoclaw-v1-agents"
[[ "${gpu}" == *"E2E_USER_OFFSET=0"* && "${gpu}" == *"E2E_USER_OFFSET=3"* && "${gpu}" == *"E2E_USER_OFFSET=6"* ]] \
  || fail "6d sandbox offsets 0, 3, and 6"
echo "${gpu}" | grep -q 'openclaw .*INFLIGHT=4' || fail "OpenClaw GPU util INFLIGHT=4"
echo "${gpu}" | grep -q 'hermes .*INFLIGHT=2' || fail "Hermes GPU util INFLIGHT=2"
echo "${gpu}" | grep -q 'deepagents .*INFLIGHT=3' || fail "Deep Agents GPU util INFLIGHT=3"

lat="$(MIXED_CLIENT_DRY_RUN=1 "${SCRIPT_DIR}/client.sh" latency_avg)"
[[ "${lat}" == *"openclaw"* && "${lat}" == *"hermes"* && "${lat}" == *"deepagents"* ]] \
  || fail "latency dry-run must start all three pairings"
echo "${lat}" | grep -q 'INFLIGHT=' && fail "latency dry-run must omit INFLIGHT"
echo "${lat}" | grep -q 'MAX_TOKENS=' && fail "latency dry-run must omit MAX_TOKENS"

leaked="$(
  NAMESPACE=wrong HPA_NAME=wrong INFLIGHT=99 MAX_TOKENS=9 V1_AGENT_KIND=hermes \
    MIXED_CLIENT_DRY_RUN=1 HPA_METRIC=gpu_utilization "${SCRIPT_DIR}/client.sh"
)"
echo "${leaked}" | grep -q 'NAMESPACE=wrong' && fail "parent NAMESPACE must not leak into 6d clients"
echo "${leaked}" | grep -q 'INFLIGHT=99' && fail "parent INFLIGHT must not replace per-pairing GPU util flags"

echo "OK: one client.sh runs OpenClaw, Hermes, and Deep Agents for GPU util and latency"
