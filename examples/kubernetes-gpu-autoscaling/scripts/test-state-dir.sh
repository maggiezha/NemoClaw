#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Load clients accept the apply --state-dir, including when terraform.tfstate
# is in a state/ subdirectory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

direct="${tmp}/direct"
nested="${tmp}/nested"
mkdir -p "${direct}" "${nested}/state"
: >"${direct}/terraform.tfstate"
: >"${nested}/state/terraform.tfstate"

[[ "$(agent_common_resolve_state_dir "${direct}")" == "${direct}" ]] \
  || fail "direct terraform.tfstate"
[[ "$(agent_common_resolve_state_dir "${nested}")" == "${nested}/state" ]] \
  || fail "nested state/terraform.tfstate"
[[ "$(agent_common_resolve_state_dir "${nested}/state")" == "${nested}/state" ]] \
  || fail "inner state directory"

if agent_common_resolve_state_dir "${tmp}/missing" >/dev/null 2>&1; then
  fail "missing state dir must fail"
fi

echo "OK: clients find terraform.tfstate in the apply directory or its state/ subdirectory"
