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
# shellcheck source=e2e-common.sh
source "${SCRIPT_DIR}/e2e-common.sh"
