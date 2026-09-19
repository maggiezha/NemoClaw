#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Pin the running OpenClaw agent to the Ollama model. No extra Node CLI."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

MODEL = sys.argv[1] if len(sys.argv) > 1 else "llama3.2:3b"
PRIMARY = MODEL if MODEL.startswith("inference/") else f"inference/{MODEL}"
BARE = PRIMARY[len("inference/") :]
PATH = pathlib.Path("/sandbox/.openclaw/openclaw.json")


def main() -> int:
    cfg = json.loads(PATH.read_text())
    cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = PRIMARY
    provider = cfg.setdefault("models", {}).setdefault("providers", {}).setdefault("inference", {})
    models = provider.get("models")
    if not isinstance(models, list) or not models or not isinstance(models[0], dict):
        provider["models"] = [{}]
        models = provider["models"]
    models[0]["id"] = BARE
    models[0]["name"] = PRIMARY
    PATH.write_text(json.dumps(cfg, indent=2) + "\n")
    try:
        digest = subprocess.check_output(["sha256sum", str(PATH)], text=True)
        (PATH.parent / ".config-hash").write_text(digest)
    except (OSError, subprocess.CalledProcessError):
        pass
    print(f"pinned {PRIMARY}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
