#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Renderer contract for step 6d: 3 OpenClaw, 3 Hermes, and 3 Deep Agents
# sandboxes, each pointed at its own GPU chart Service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

unset MIXED_NAME MIXED_UID NEMOCLAW_TARGET_NODE V1_NAMESPACE GATEWAY_CONTEXT \
  OPENCLAW_IMAGE_REF HERMES_IMAGE_REF DEEPAGENTS_IMAGE_REF
rendered="$("${SCRIPT_DIR}/render-mixed-sandboxes.sh")"

python3 -c '
import re
import sys
import yaml

doc = yaml.safe_load(sys.stdin.read())
spec = doc["spec"]
namespace = spec["gateway"]["kubernetes"]["namespace"]
if namespace != "nemoclaw-v1-agents":
    raise SystemExit(f"namespace {namespace}")
providers = spec["inferenceProviders"]
ollama = providers["gpu-ollama"]["endpoint"]
vllm = providers["gpu-vllm"]["endpoint"]
nim = providers["gpu-nim"]["endpoint"]
if ollama != "http://nemoclaw-gpu-ollama-metrics-proxy.nemoclaw-gpu.svc.cluster.local:8081/v1":
    raise SystemExit(f"ollama endpoint {ollama}")
if vllm != "http://nemoclaw-gpu-vllm-metrics-proxy.nemoclaw-gpu.svc.cluster.local:8081/v1":
    raise SystemExit(f"vllm endpoint {vllm}")
if nim != "http://nemoclaw-gpu-nim-metrics-proxy.nemoclaw-gpu.svc.cluster.local:8081/v1":
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
name = doc["metadata"]["name"]
if name != "gpu-autoscaling-mixed":
    raise SystemExit("default mixed name " + name)
if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", name):
    raise SystemExit("metadata.name fails schema pattern: " + name)
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
cfg = doc["spec"]["gateway"]["config"]["openshell.drivers.kubernetes"]
if cfg.get("allow_driver_config") is not True:
    raise SystemExit(f"allow_driver_config {cfg}")
if cfg.get("image_pull_policy") != "if_not_present":
    raise SystemExit(f"image_pull_policy {cfg}")
' <<<"${pinned}"

adapted="$(
  GATEWAY_CONTEXT=kubernetes-admin@kubernetes \
  OPENCLAW_IMAGE_REF='docker.io/library/nc-fabric@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  HERMES_IMAGE_REF='docker.io/library/nc-fabric@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  DEEPAGENTS_IMAGE_REF='docker.io/library/nc-fabric@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    "${SCRIPT_DIR}/render-mixed-sandboxes.sh"
)"
python3 -c '
import sys
import yaml

doc = yaml.safe_load(sys.stdin.read())
ctx = doc["spec"]["gateway"]["kubernetes"]["context"]
if ctx != "kubernetes-admin@kubernetes":
    raise SystemExit(f"context {ctx}")
refs = {
    name: doc["spec"]["sandboxes"][name]["image"]["ref"]
    for name in ("user-0000", "user-0003", "user-0006")
}
if not refs["user-0000"].endswith("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"):
    raise SystemExit("openclaw ref " + refs["user-0000"])
if not refs["user-0003"].endswith("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"):
    raise SystemExit("hermes ref " + refs["user-0003"])
if not refs["user-0006"].endswith("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"):
    raise SystemExit("deepagents ref " + refs["user-0006"])
' <<<"${adapted}"

echo "OK: 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes use separate inference Services"
