#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One terminal: GPU-chart HPAs, metrics-proxy pods, and DCGM GPU index.
# Each row is hermes-vllm / openclaw-ollama, not a metrics-proxy object name.
#
# Usage:
#   ./scripts/get-hpa.sh
#   ./scripts/get-hpa.sh -w
#   ./scripts/get-hpa.sh -n nemoclaw-gpu -w
#   HPA_WATCH_INTERVAL_SEC=5 ./scripts/get-hpa.sh -w

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hpa-common.sh
source "${SCRIPT_DIR}/hpa-common.sh"

hpa_common_load_local_env "$(cd "${SCRIPT_DIR}/.." && pwd)"

# Only -n pins a namespace. Do not inherit NAMESPACE from install scripts.
NAMESPACE=""
WATCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n | --namespace)
      NAMESPACE="${2:?namespace required after -n}"
      shift 2
      ;;
    -w | --watch)
      WATCH=1
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [-n NAMESPACE] [-w]

One screen for every nemoclaw-gpu* HPA: hermes-vllm / openclaw-ollama,
replica count, GPU pods, and which GPU index runs which pairing.

  -n NAMESPACE            one GPU-chart namespace; default is all nemoclaw-gpu*
  -w                      refresh in this terminal
  HPA_WATCH_INTERVAL_SEC  poll interval for -w (default 2)

Examples:
  $(basename "$0")
  $(basename "$0") -w
  $(basename "$0") -n nemoclaw-gpu -w
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

require_cmd kubectl
require_cmd python3

if [[ "${WATCH}" -eq 1 ]]; then
  hpa_common_watch_cluster "${NAMESPACE}"
  exit 0
fi

hpa_common_print_cluster "${NAMESPACE}"
