#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Compatibility name. The OpenClaw + Ollama e2e helper is:
#   ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh
set -euo pipefail
echo "OpenClaw + Ollama e2e helper moved to ./scripts/setup-openclaw-ollama-e2e-sandboxes.sh" >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-openclaw-ollama-e2e-sandboxes.sh" "$@"
