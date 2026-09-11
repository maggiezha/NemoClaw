#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One-script path for Deep Agents Code + vLLM. Does not run the HPA load test
# unless RUN_LOAD_TEST=1. See ../README.md#agent-and-runtime-support

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"
agent_common_pin_example_pairing deepagents vllm
export RUN_LOAD_TEST="${RUN_LOAD_TEST:-0}"
# Isolated from Ollama (nemoclaw-gpu) and Hermes+NIM (nemoclaw-hermes-nim).
export NAMESPACE="${NAMESPACE:-nemoclaw-deepagents-vllm}"
export RELEASE="${RELEASE:-deepagents-vllm}"
export MIN_REPLICAS="${MIN_REPLICAS:-1}"
export MAX_REPLICAS="${MAX_REPLICAS:-1}"
export ENABLE_ENVOY_LB="${ENABLE_ENVOY_LB:-0}"
export USE_EXISTING_PROMETHEUS="${USE_EXISTING_PROMETHEUS:-auto}"
export SKIP_MONITORING="${SKIP_MONITORING:-1}"
# shellcheck source=e2e-common.sh
source "${SCRIPT_DIR}/e2e-common.sh"
