#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Static contract for the README documented example pairings (no cluster).
# Cluster tests: test-openclaw-ollama.sh, test-hermes-vllm.sh, test-deepagents-vllm.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local desc="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail "${desc} should have been refused"
  fi
}

agent_common_validate_runtime_pairing openclaw ollama
agent_common_validate_runtime_pairing hermes vllm
agent_common_validate_runtime_pairing deepagents vllm
agent_common_validate_runtime_pairing openclaw vllm
agent_common_validate_runtime_pairing hermes ollama
agent_common_validate_runtime_pairing deepagents nim
expect_fail "deepagents+ollama" agent_common_validate_runtime_pairing deepagents ollama
expect_fail "deepagents with empty runtime" agent_common_validate_runtime_pairing deepagents ""

PAIRING_COUNT=0
while IFS=$'\t' read -r agent runtime model; do
  PAIRING_COUNT=$((PAIRING_COUNT + 1))
  agent_common_is_example_pairing "${agent}" "${runtime}" \
    || fail "${agent}+${runtime} is missing from agent_common_is_example_pairing"
  [[ "$(agent_common_example_model "${agent}" "${runtime}")" == "${model}" ]] \
    || fail "${agent}+${runtime} example model is not ${model}"
  [[ "$(agent_common_default_inference_model "${runtime}")" == "${model}" ]] \
    || fail "${runtime} default model drifted from the ${agent}+${runtime} example"
  script="$(agent_common_example_test_script "${agent}" "${runtime}")"
  [[ -x "${SCRIPT_DIR}/${script}" ]] \
    || fail "${script} missing or not executable"
  grep -Fq "test-agent-runtime-example.sh\" ${agent} ${runtime}" "${SCRIPT_DIR}/${script}" \
    || fail "${script} must exec test-agent-runtime-example.sh ${agent} ${runtime}"
  grep -Fq "${script}" "${CHART_DIR}/README.md" \
    || fail "README.md must link ${script} next to the ${agent}+${runtime} example"
  grep -Fq "${script}" "${CHART_DIR}/AGENT-SELECTION.md" \
    || fail "AGENT-SELECTION.md must link ${script}"
done < <(agent_common_example_pairings)

[[ "${PAIRING_COUNT}" -eq 3 ]] || fail "expected 3 README example pairings, got ${PAIRING_COUNT}"
agent_common_is_example_pairing deepagents ollama \
  && fail "deepagents+ollama must not be a README example pairing"

grep -Fq '**OpenClaw** — Ollama' "${CHART_DIR}/README.md" \
  || fail "README OpenClaw example bullet missing"
grep -Fq '**Hermes** — vLLM' "${CHART_DIR}/README.md" \
  || fail "README Hermes example bullet missing"
grep -Fq '**Deep Agents Code** — vLLM' "${CHART_DIR}/README.md" \
  || fail "README Deep Agents example bullet missing"

GENERIC="${SCRIPT_DIR}/test-agent-runtime-example.sh"
[[ -x "${GENERIC}" ]] || fail "test-agent-runtime-example.sh missing or not executable"
grep -Fq 'exec "${SCRIPT_DIR}/try-it.sh"' "${GENERIC}" \
  || fail "example cluster test must exec try-it.sh"
grep -Fq 'RUN_LOAD_TEST:-0' "${GENERIC}" \
  || fail "example cluster tests should default RUN_LOAD_TEST=0"

for script in \
  "${SCRIPT_DIR}/create-agent-sandbox.sh" \
  "${SCRIPT_DIR}/build-agent-sandbox-image.sh" \
  "${SCRIPT_DIR}/verify-agent-sandbox.sh" \
  "${SCRIPT_DIR}/run-agent-prompt.sh" \
  "${SCRIPT_DIR}/try-it.sh" \
  "${SCRIPT_DIR}/install-hpa.sh"; do
  grep -Fq 'agent_common_validate_runtime_pairing' "${script}" \
    || fail "$(basename "${script}") must call agent_common_validate_runtime_pairing"
done

if grep -Fq 'if [[ "${AGENT_NAME}" == "deepagents" ]]; then' "${SCRIPT_DIR}/try-it.sh"; then
  fail "try-it.sh must use agent_common_validate_runtime_pairing, not an inline Deep Agents+Ollama check"
fi

echo "OK: README example pairings (openclaw+ollama, hermes+vllm, deepagents+vllm) have tests and docs links"
