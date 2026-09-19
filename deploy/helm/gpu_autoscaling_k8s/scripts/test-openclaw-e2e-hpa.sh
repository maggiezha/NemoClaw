#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Compatibility name. The OpenClaw + Ollama e2e is:
#   ./scripts/test-openclaw-ollama-e2e-hpa.sh
set -euo pipefail
echo "OpenClaw + Ollama e2e moved to ./scripts/test-openclaw-ollama-e2e-hpa.sh" >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-openclaw-ollama-e2e-hpa.sh" "$@"
