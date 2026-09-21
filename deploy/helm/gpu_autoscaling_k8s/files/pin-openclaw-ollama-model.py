#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Pin OpenClaw to the Ollama model and keep the sandbox light. No extra Node CLI."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

MODEL = sys.argv[1] if len(sys.argv) > 1 else "llama3.2:3b"
PRIMARY = MODEL if MODEL.startswith("inference/") else f"inference/{MODEL}"
BARE = PRIMARY[len("inference/") :]
PATH = pathlib.Path("/sandbox/.openclaw/openclaw.json")
KEEP_PLUGINS = {"nemoclaw"}


def _enable_keep_only(entries: dict) -> None:
    if "nemoclaw" not in entries:
        entries["nemoclaw"] = {}
    for key, value in list(entries.items()):
        blob = dict(value) if isinstance(value, dict) else {}
        keep = key in KEEP_PLUGINS or str(key).startswith("nemoclaw")
        blob["enabled"] = keep
        entries[key] = blob


def main() -> int:
    cfg = json.loads(PATH.read_text())
    defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
    defaults.setdefault("model", {})["primary"] = PRIMARY
    defaults["skipBootstrap"] = True
    defaults["thinkingDefault"] = "off"
    defaults.pop("heartbeat", None)

    provider = cfg.setdefault("models", {}).setdefault("providers", {}).setdefault("inference", {})
    models = provider.get("models")
    if not isinstance(models, list) or not models or not isinstance(models[0], dict):
        provider["models"] = [{}]
        models = provider["models"]
    models[0]["id"] = BARE
    models[0]["name"] = PRIMARY

    plugins = cfg.setdefault("plugins", {})
    entries = plugins.setdefault("entries", {})
    if not isinstance(entries, dict):
        entries = {}
        plugins["entries"] = entries
    _enable_keep_only(entries)
    plugins["allow"] = sorted(KEEP_PLUGINS)

    tools = cfg.setdefault("tools", {})
    tools["toolSearch"] = False
    web = tools.setdefault("web", {})
    if not isinstance(web, dict):
        web = {}
        tools["web"] = web
    web["search"] = {"enabled": False}
    web["fetch"] = {"enabled": False, "useTrustedEnvProxy": True}

    gateway = cfg.setdefault("gateway", {})
    gateway["reload"] = {"mode": "off"}
    ui = gateway.setdefault("controlUi", {})
    if isinstance(ui, dict):
        ui["dangerouslyDisableDeviceAuth"] = True

    cfg.setdefault("update", {})["checkOnStart"] = False

    PATH.write_text(json.dumps(cfg, indent=2) + "\n")
    last_good = PATH.with_name("openclaw.json.last-good")
    last_good.write_text(PATH.read_text())
    try:
        digest = subprocess.check_output(["sha256sum", str(PATH)], text=True)
        (PATH.parent / ".config-hash").write_text(digest)
    except (OSError, subprocess.CalledProcessError):
        pass
    for target in (PATH, last_good, PATH.parent / ".config-hash"):
        try:
            os.chown(target, 1000, 1000)
        except OSError:
            pass
    print(f"pinned {PRIMARY} (light plugins={','.join(sorted(KEEP_PLUGINS))})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
