#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Cluster test for one README documented example pairing. Pins AGENT_NAME /
# INFERENCE_RUNTIME / INFERENCE_MODEL, then execs try-it.sh.
#
# Usage (from deploy/helm/gpu_autoscaling_k8s):
#   ./scripts/test-agent-runtime-example.sh openclaw ollama
#   ./scripts/test-openclaw-ollama.sh
#   ./scripts/test-hermes-vllm.sh
#   ./scripts/test-deepagents-vllm.sh
#
# Pairing-focused by default (RUN_LOAD_TEST=0). Set RUN_LOAD_TEST=1 to also run
# hpa-load-test.sh. Same security opt-in as try-it.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"

usage() {
  echo "Usage: $0 <openclaw|hermes|deepagents> <ollama|vllm|nim>" >&2
  echo "Documented example pairings:" >&2
  while IFS=$'\t' read -r agent runtime model; do
    echo "  $0 ${agent} ${runtime}   # ${model}  ($(agent_common_example_test_script "${agent}" "${runtime}"))" >&2
  done < <(agent_common_example_pairings)
  echo "Other documented pairings: AGENT_NAME=… INFERENCE_RUNTIME=… ./scripts/try-it.sh" >&2
}

AGENT="${1:-}"
RUNTIME="${2:-}"
if [[ -z "${AGENT}" || -z "${RUNTIME}" ]]; then
  usage
  exit 1
fi

if ! agent_common_is_example_pairing "${AGENT}" "${RUNTIME}"; then
  echo "ERROR: ${AGENT}+${RUNTIME} is not a README example pairing." >&2
  usage
  exit 1
fi

if [[ -n "${AGENT_NAME:-}" && "${AGENT_NAME}" != "${AGENT}" ]]; then
  echo "ERROR: AGENT_NAME=${AGENT_NAME} does not match this example (${AGENT}). Unset it or use try-it.sh." >&2
  exit 1
fi
if [[ -n "${INFERENCE_RUNTIME:-}" && "${INFERENCE_RUNTIME}" != "${RUNTIME}" ]]; then
  echo "ERROR: INFERENCE_RUNTIME=${INFERENCE_RUNTIME} does not match this example (${RUNTIME}). Unset it or use try-it.sh." >&2
  exit 1
fi

export AGENT_NAME="${AGENT}"
export INFERENCE_RUNTIME="${RUNTIME}"
export INFERENCE_MODEL="${INFERENCE_MODEL:-$(agent_common_example_model "${AGENT}" "${RUNTIME}")}"
agent_common_validate_runtime_pairing "${AGENT_NAME}" "${INFERENCE_RUNTIME}"
export RUN_LOAD_TEST="${RUN_LOAD_TEST:-0}"

exec "${SCRIPT_DIR}/try-it.sh"
