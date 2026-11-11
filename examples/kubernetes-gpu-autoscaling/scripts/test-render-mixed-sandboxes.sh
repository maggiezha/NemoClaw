#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Renderer contract for step 6d: 3 OpenClaw, 3 Hermes, and 3 Deep Agents
# sandboxes, each pointed at its own GPU chart Service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

unset MIXED_NAME MIXED_UID NEMOCLAW_TARGET_NODE
rendered="$("${SCRIPT_DIR}/render-mixed-sandboxes.sh")"

python3 -c '
import sys
import yaml

doc = yaml.safe_load(sys.stdin.read())
spec = doc["spec"]
namespace = spec["gateway"]["kubernetes"]["namespace"]
if namespace != "nemoclaw-v1-gpu-autoscaling-mixed":
    raise SystemExit(f"namespace {namespace}")
providers = spec["inferenceProviders"]
ollama = providers["gpu-ollama"]["endpoint"]
vllm = providers["gpu-vllm"]["endpoint"]
nim = providers["gpu-nim"]["endpoint"]
if ollama != "http://nemoclaw-gpu-ollama-metrics-proxy.nemoclaw-gpu-ollama.svc.cluster.local:8081/v1":
    raise SystemExit(f"ollama endpoint {ollama}")
if vllm != "http://nemoclaw-gpu-vllm-metrics-proxy.nemoclaw-gpu-vllm.svc.cluster.local:8081/v1":
    raise SystemExit(f"vllm endpoint {vllm}")
if nim != "http://nemoclaw-gpu-nim-metrics-proxy.nemoclaw-gpu-nim.svc.cluster.local:8081/v1":
    raise SystemExit(f"nim endpoint {nim}")
if providers["gpu-ollama"]["credential"]["env"] != "GPU_OLLAMA_API_KEY":
    raise SystemExit("ollama credential env")
if providers["gpu-vllm"]["credential"]["env"] != "GPU_VLLM_API_KEY":
    raise SystemExit("vllm credential env")
if providers["gpu-nim"]["credential"]["env"] != "GPU_NIM_API_KEY":
    raise SystemExit("nim credential env")
sandboxes = spec["sandboxes"]
if list(sandboxes) != [f"user-{i:04d}" for i in range(9)]:
    raise SystemExit(f"sandbox names {list(sandboxes)}")
for name in ("user-0000", "user-0001", "user-0002"):
    sandbox = sandboxes[name]
    if sandbox["harness"]["kind"] != "nvidia.fabric.openclaw":
        raise SystemExit(f"{name} harness")
    if sandbox["image"]["metadata"]["env"] != "NEMOCLAW_OPENCLAW_IMAGE_METADATA":
        raise SystemExit(f"{name} metadata")
    if sandbox["agent"]["inference"]["routes"][0]["providerRef"] != "gpu-ollama":
        raise SystemExit(f"{name} provider")
    if sandbox["agent"]["inference"]["routes"][0]["overrides"]["model"] != "llama3.2:3b":
        raise SystemExit(f"{name} model")
for name in ("user-0003", "user-0004", "user-0005"):
    sandbox = sandboxes[name]
    if sandbox["harness"]["kind"] != "nvidia.fabric.hermes":
        raise SystemExit(f"{name} harness")
    if sandbox["image"]["metadata"]["env"] != "NEMOCLAW_HERMES_IMAGE_METADATA":
        raise SystemExit(f"{name} metadata")
    if sandbox["agent"]["inference"]["routes"][0]["providerRef"] != "gpu-vllm":
        raise SystemExit(f"{name} provider")
    if sandbox["agent"]["inference"]["routes"][0]["overrides"]["model"] != "nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8":
        raise SystemExit(f"{name} model")
for name in ("user-0006", "user-0007", "user-0008"):
    sandbox = sandboxes[name]
    if sandbox["harness"]["kind"] != "nvidia.fabric.langchain.deepagents":
        raise SystemExit(f"{name} harness")
    if sandbox["image"]["metadata"]["env"] != "NEMOCLAW_DEEPAGENTS_IMAGE_METADATA":
        raise SystemExit(f"{name} metadata")
    if sandbox["agent"]["inference"]["routes"][0]["providerRef"] != "gpu-nim":
        raise SystemExit(f"{name} provider")
    if sandbox["agent"]["inference"]["routes"][0]["overrides"]["model"] != "nvidia/nemotron-3-nano":
        raise SystemExit(f"{name} model")
if "driverConfig" in sandboxes["user-0000"]:
    raise SystemExit("default render pins a node")
if doc["metadata"]["name"] != "gpu-autoscaling-openclaw-hermes-deepagents":
    raise SystemExit("default mixed name")
' <<<"${rendered}"

pinned="$(
  MIXED_NAME=gpu-autoscaling-openclaw-hermes \
    MIXED_UID=a1f3a3ed-2539-4922-be43-d0695248fb91 \
    NEMOCLAW_TARGET_NODE=gpu-node \
    "${SCRIPT_DIR}/render-mixed-sandboxes.sh"
)"
python3 -c '
import sys
import yaml

doc = yaml.safe_load(sys.stdin.read())
if doc["metadata"]["name"] != "gpu-autoscaling-openclaw-hermes":
    raise SystemExit("override mixed name")
if doc["metadata"]["uid"] != "a1f3a3ed-2539-4922-be43-d0695248fb91":
    raise SystemExit("override mixed uid")
selector = (
    doc["spec"]["sandboxes"]["user-0008"]["driverConfig"]["kubernetes"]["pod"]["node_selector"]
)
if selector != {"kubernetes.io/hostname": "gpu-node"}:
    raise SystemExit(f"node selector {selector}")
' <<<"${pinned}"

echo "OK: 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes use separate inference Services"
