#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Load-test and HPA watch lines name both the Fabric agent and the GPU runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset V1_AGENT_KIND INFERENCE_RUNTIME || true
# shellcheck source=agent-common.sh
source "${SCRIPT_DIR}/agent-common.sh"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(agent_common_pairing_label openclaw ollama)" == "openclaw + ollama" ]] \
  || fail "openclaw pairing label"
[[ "$(agent_common_pairing_label hermes vllm)" == "hermes + vllm" ]] \
  || fail "hermes pairing label"
[[ "$(agent_common_pairing_label deepagents nim)" == "deepagents + nim" ]] \
  || fail "deepagents pairing label"

[[ "$(agent_common_agent_for_runtime ollama)" == "openclaw" ]] \
  || fail "ollama maps to openclaw"
[[ "$(agent_common_agent_for_runtime vllm)" == "hermes" ]] \
  || fail "vllm maps to hermes"
[[ "$(agent_common_agent_for_runtime nim)" == "deepagents" ]] \
  || fail "nim maps to deepagents"

[[ "$(agent_common_runtime_from_namespace nemoclaw-gpu-ollama)" == "ollama" ]] \
  || fail "6d ollama namespace"
[[ "$(agent_common_runtime_from_namespace nemoclaw-gpu-vllm)" == "vllm" ]] \
  || fail "6d vllm namespace"
[[ "$(agent_common_runtime_from_namespace nemoclaw-gpu-nim)" == "nim" ]] \
  || fail "nim namespace"
if agent_common_runtime_from_namespace nemoclaw-gpu; then
  fail "default namespace must not invent a runtime"
fi

[[ "$(hpa_common_pairing_label_for_namespace nemoclaw-gpu-ollama)" == "openclaw + ollama" ]] \
  || fail "HPA watch label for ollama namespace"
[[ "$(hpa_common_pairing_label_for_namespace nemoclaw-gpu-vllm)" == "hermes + vllm" ]] \
  || fail "HPA watch label for vllm namespace"
[[ "$(hpa_common_pairing_label_for_namespace nemoclaw-gpu-nim)" == "deepagents + nim" ]] \
  || fail "HPA watch label for nim namespace"

[[ "$(hpa_common_live_runtime_line ollama)" == "Live pairing: openclaw + ollama" ]] \
  || fail "live runtime line names openclaw and ollama"
[[ "$(hpa_common_live_runtime_line vllm)" == "Live pairing: hermes + vllm" ]] \
  || fail "live runtime line names hermes and vllm"
[[ "$(hpa_common_live_runtime_line nim)" == "Live pairing: deepagents + nim" ]] \
  || fail "live runtime line names deepagents and nim"

banner="$(INFERENCE_RUNTIME=ollama INFLIGHT=4 MAX_TOKENS=2048 \
  agent_common_print_load_banner 900 0 openclaw)"
[[ "${banner}" == *"openclaw + ollama"* ]] || fail "load banner names openclaw + ollama"
[[ "${banner}" == *"openclaw"* && "${banner}" == *"ollama"* ]] \
  || fail "load banner includes both names"

banner="$(INFERENCE_RUNTIME=vllm INFLIGHT=2 MAX_TOKENS=1024 \
  agent_common_print_load_banner 900 0 hermes)"
[[ "${banner}" == *"hermes + vllm"* ]] || fail "load banner names hermes + vllm"

banner="$(INFERENCE_RUNTIME=nim INFLIGHT=3 MAX_TOKENS=1024 \
  agent_common_print_load_banner 900 0 deepagents)"
[[ "${banner}" == *"deepagents + nim"* ]] || fail "load banner names deepagents + nim"

python3 - "${SCRIPT_DIR}/e2e-fabric-load-test.py" <<'PY'
import importlib.util
import io
import os
import sys
from contextlib import redirect_stdout
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("e2e_fabric_load_test", path)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

assert mod.pairing_label("openclaw", "ollama") == "openclaw + ollama"
assert mod.pairing_label("hermes", "vllm") == "hermes + vllm"
assert mod.pairing_label("deepagents", "nim") == "deepagents + nim"

os.environ["V1_AGENT_KIND"] = "openclaw"
os.environ["INFERENCE_RUNTIME"] = "ollama"
buf = io.StringIO()
with redirect_stdout(buf):
    mod.print_load_header(2, 4, 4)
text = buf.getvalue()
if "openclaw + ollama" not in text:
    raise SystemExit(f"openclaw load header missing pairing:\n{text}")
if "Hermes agents" in text:
    raise SystemExit(f"openclaw load header still says Hermes:\n{text}")

os.environ["V1_AGENT_KIND"] = "hermes"
os.environ["INFERENCE_RUNTIME"] = "vllm"
buf = io.StringIO()
with redirect_stdout(buf):
    mod.print_load_header(6, 2, 2)
text = buf.getvalue()
if "hermes + vllm" not in text:
    raise SystemExit(f"hermes load header missing pairing:\n{text}")

os.environ["V1_AGENT_KIND"] = "deepagents"
os.environ["INFERENCE_RUNTIME"] = "nim"
buf = io.StringIO()
with redirect_stdout(buf):
    mod.print_load_header(10, 3, 3)
text = buf.getvalue()
if "deepagents + nim" not in text:
    raise SystemExit(f"deepagents load header missing pairing:\n{text}")
PY

echo "OK: watches and clients name both the agent and the inference runtime"
