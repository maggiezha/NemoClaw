#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Print one NemoClawConfig with OpenClaw, Hermes, and Deep Agents sandboxes.
# OpenClaw calls the Ollama release. Hermes calls the vLLM release. Deep
# Agents calls the NIM release. Does not apply.
#
#   ./scripts/render-mixed-sandboxes.sh > .local/openclaw-hermes-deepagents.yaml
#
# Defaults: 3 OpenClaw sandboxes (user-0000 through user-0002), 3 Hermes
# sandboxes (user-0003 through user-0005), and 3 Deep Agents sandboxes
# (user-0006 through user-0008). Image digests come from OPENCLAW_IMAGE_REF,
# HERMES_IMAGE_REF, and DEEPAGENTS_IMAGE_REF, or from the pairing files.
# Gateway context comes from GATEWAY_CONTEXT or kubectl. NEMOCLAW_TARGET_NODE
# pins sandboxes and sets allow_driver_config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENCLAW_USERS="${OPENCLAW_USERS:-3}"
HERMES_USERS="${HERMES_USERS:-3}"
DEEPAGENTS_USERS="${DEEPAGENTS_USERS:-3}"
VLLM_RELEASE="${VLLM_RELEASE:-nemoclaw-gpu-vllm}"
OLLAMA_RELEASE="${OLLAMA_RELEASE:-nemoclaw-gpu-ollama}"
NIM_RELEASE="${NIM_RELEASE:-nemoclaw-gpu-nim}"
GPU_NAMESPACE="${GPU_NAMESPACE:-nemoclaw-gpu}"

if [[ ! "${OPENCLAW_USERS}" =~ ^[0-9]+$ || ! "${HERMES_USERS}" =~ ^[0-9]+$ || ! "${DEEPAGENTS_USERS}" =~ ^[0-9]+$ ]]; then
  echo "OPENCLAW_USERS, HERMES_USERS, and DEEPAGENTS_USERS must be integers" >&2
  exit 2
fi
if ((OPENCLAW_USERS < 1 || HERMES_USERS < 1 || DEEPAGENTS_USERS < 1)); then
  echo "OPENCLAW_USERS, HERMES_USERS, and DEEPAGENTS_USERS must be at least 1" >&2
  exit 2
fi
if ((OPENCLAW_USERS + HERMES_USERS + DEEPAGENTS_USERS > 32)); then
  echo "OPENCLAW_USERS + HERMES_USERS + DEEPAGENTS_USERS must be at most 32" >&2
  exit 2
fi

python3 - "${EXAMPLE_DIR}" "${OPENCLAW_USERS}" "${HERMES_USERS}" "${DEEPAGENTS_USERS}" \
  "${OLLAMA_RELEASE}" "${VLLM_RELEASE}" "${NIM_RELEASE}" "${GPU_NAMESPACE}" <<'PY'
import copy
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

example = Path(sys.argv[1])
openclaw_users = int(sys.argv[2])
hermes_users = int(sys.argv[3])
deepagents_users = int(sys.argv[4])
ollama_release = sys.argv[5]
vllm_release = sys.argv[6]
nim_release = sys.argv[7]
gpu_namespace = sys.argv[8]


class DumpWithoutAliases(yaml.SafeDumper):
    def ignore_aliases(self, data):
        return True


def load_pairing(name: str) -> dict:
    path = example / f"{name}.yaml"
    if not path.is_file():
        raise SystemExit(f"missing pairing file: {path}")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def first_sandbox(doc: dict, path_name: str) -> dict:
    sandboxes = doc["spec"]["sandboxes"]
    if not sandboxes:
        raise SystemExit(f"{path_name}: spec.sandboxes is empty")
    return next(iter(sandboxes.values()))


def service_url(release: str) -> str:
    return (
        f"http://{release}-metrics-proxy.{gpu_namespace}.svc.cluster.local:8081/v1"
    )


openclaw = load_pairing("openclaw-ollama")
hermes = load_pairing("hermes-vllm")
deepagents = load_pairing("deepagents-nim")
openclaw_template = first_sandbox(openclaw, "openclaw-ollama.yaml")
hermes_template = first_sandbox(hermes, "hermes-vllm.yaml")
deepagents_template = first_sandbox(deepagents, "deepagents-nim.yaml")

doc = copy.deepcopy(openclaw)
doc["metadata"]["name"] = os.environ.get("MIXED_NAME") or "gpu-autoscaling-mixed"
doc["metadata"]["uid"] = os.environ.get("MIXED_UID") or "a7c3e1b2-4d58-4f0a-9c6e-2b8f0d1e6a44"
gateway = doc["spec"]["gateway"]
gateway["endpoint"] = "https://127.0.0.1:17673"
gateway["kubernetes"]["namespace"] = os.environ.get("V1_NAMESPACE") or "nemoclaw-v1-agents"
context = (os.environ.get("GATEWAY_CONTEXT") or "").strip()
if not context and shutil.which("kubectl"):
    try:
        got = subprocess.run(
            ["kubectl", "config", "current-context"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        context = (got.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired):
        context = ""
if context:
    gateway["kubernetes"]["context"] = context
target_node = (os.environ.get("NEMOCLAW_TARGET_NODE") or "").strip()
if target_node:
    drivers = (
        gateway.setdefault("config", {})
        .setdefault("openshell.drivers.kubernetes", {})
    )
    drivers["allow_driver_config"] = True
    drivers["image_pull_policy"] = "if_not_present"


def provider(source_name: str, source: dict, endpoint: str, credential_env: str) -> dict:
    raw = source["spec"]["inferenceProviders"][source_name]
    return {
        "provider": raw["provider"],
        "api": raw["api"],
        "endpoint": endpoint,
        "credential": {"env": credential_env},
    }


doc["spec"]["inferenceProviders"] = {
    "gpu-ollama": provider(
        "gpu-ollama",
        openclaw,
        service_url(ollama_release),
        "GPU_OLLAMA_API_KEY",
    ),
    "gpu-vllm": provider(
        "gpu-vllm",
        hermes,
        service_url(vllm_release),
        "GPU_VLLM_API_KEY",
    ),
    "gpu-nim": provider(
        "gpu-nim",
        deepagents,
        service_url(nim_release),
        "GPU_NIM_API_KEY",
    ),
}


image_refs = {
    "gpu-ollama": (os.environ.get("OPENCLAW_IMAGE_REF") or "").strip(),
    "gpu-vllm": (os.environ.get("HERMES_IMAGE_REF") or "").strip(),
    "gpu-nim": (os.environ.get("DEEPAGENTS_IMAGE_REF") or "").strip(),
}


def place(template: dict, provider_ref: str, metadata_env: str) -> dict:
    sandbox = copy.deepcopy(template)
    sandbox["image"]["metadata"] = {"env": metadata_env}
    image_ref = image_refs.get(provider_ref) or ""
    if image_ref:
        sandbox["image"]["ref"] = image_ref
    routes = sandbox["agent"]["inference"]["routes"]
    routes[0]["providerRef"] = provider_ref
    if target_node:
        pod = (
            sandbox.setdefault("driverConfig", {})
            .setdefault("kubernetes", {})
            .setdefault("pod", {})
        )
        pod["node_selector"] = {"kubernetes.io/hostname": target_node}
    return sandbox


sandboxes = {}
offset = 0
for index in range(openclaw_users):
    sandboxes[f"user-{offset + index:04d}"] = place(
        openclaw_template, "gpu-ollama", "NEMOCLAW_OPENCLAW_IMAGE_METADATA"
    )
offset += openclaw_users
for index in range(hermes_users):
    sandboxes[f"user-{offset + index:04d}"] = place(
        hermes_template, "gpu-vllm", "NEMOCLAW_HERMES_IMAGE_METADATA"
    )
offset += hermes_users
for index in range(deepagents_users):
    sandboxes[f"user-{offset + index:04d}"] = place(
        deepagents_template, "gpu-nim", "NEMOCLAW_DEEPAGENTS_IMAGE_METADATA"
    )
doc["spec"]["sandboxes"] = sandboxes

sys.stdout.write(
    "# Generated by scripts/render-mixed-sandboxes.sh. Do not edit by hand.\n"
)
yaml.dump(doc, sys.stdout, Dumper=DumpWithoutAliases, sort_keys=False)
PY
