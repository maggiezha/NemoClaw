#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Format one GPU-chart watch: HPA, pods, and GPU index.

Rows use hermes-vllm / openclaw-ollama, not Kubernetes metrics-proxy names.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

RUNTIME_AGENT = {
    "ollama": "openclaw",
    "vllm": "hermes",
    "nim": "deepagents",
}
_RUNTIME_TOKEN = re.compile(r"(?:^|-)(ollama|vllm|nim)(?:-|$)")
_PROXY_SUFFIX = re.compile(r"-metrics-proxy(?:-(.+))?$")
GPU_NS_RE = re.compile(r"^nemoclaw-gpu(?:-.*)?$")
NAME_W = 24


def runtime_from_name(name: str) -> str:
    if not name:
        return ""
    matches = _RUNTIME_TOKEN.findall(name.lower())
    return matches[-1] if matches else ""


def pairing_for_name(name: str, namespace: str = "") -> str:
    runtime = runtime_from_name(name) or runtime_from_name(namespace)
    agent = RUNTIME_AGENT.get(runtime, "")
    if not agent or not runtime:
        return ""
    return f"{agent} + {runtime}"


def display_name(name: str, namespace: str = "") -> str:
    pairing = pairing_for_name(name, namespace)
    if not pairing:
        return name
    slug = pairing.replace(" + ", "-")
    extra = ""
    match = _PROXY_SUFFIX.search(name)
    if match and match.group(1):
        extra = match.group(1).rsplit("-", 1)[-1]
    elif name.startswith(f"{slug}-"):
        extra = name[len(slug) + 1 :].rsplit("-", 1)[-1]
    if extra:
        return f"{slug}-{extra}"
    return slug


def qty(raw: Any) -> float | None:
    if raw is None:
        return None
    s = str(raw).strip()
    if not s or s == "<unknown>":
        return None
    m = re.fullmatch(
        r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))(n|u|m|k|Ki|Mi|Gi|Ti|Pi|Ei|[KMGTP])?",
        s,
    )
    if not m:
        return None
    n = float(m.group(1))
    suf = m.group(2) or ""
    scale = {
        "n": 1e-9,
        "u": 1e-6,
        "m": 1e-3,
        "": 1.0,
        "k": 1e3,
        "M": 1e6,
        "G": 1e9,
        "T": 1e12,
        "P": 1e15,
        "E": 1e18,
        "Ki": 1024.0,
        "Mi": 1024.0**2,
        "Gi": 1024.0**3,
        "Ti": 1024.0**4,
        "Pi": 1024.0**5,
        "Ei": 1024.0**6,
    }[suf]
    return n * scale


def fmt_pct(n: float | None) -> str:
    if n is None:
        return "<unknown>"
    if abs(n - round(n)) < 1e-6:
        return f"{int(round(n))}%"
    s = f"{n:.2f}".rstrip("0").rstrip(".")
    return f"{s}%"


def fmt_ms(n: float | None) -> str:
    if n is None:
        return "0"
    if abs(n - round(n)) < 0.05:
        return str(int(round(n)))
    return f"{n:.2f}".rstrip("0").rstrip(".")


def age(ts: str | None) -> str:
    if not ts:
        return "?"
    created = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    secs = int((datetime.now(timezone.utc) - created).total_seconds())
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def metric_kind(name: str) -> str:
    if name == "gpu_utilization_percent":
        return "gpu_utilization"
    if name == "nemoclaw_llm_latency_avg_milliseconds":
        return "latency"
    return "other"


def hpa_metric_name(hpa: dict[str, Any]) -> str:
    for sm in hpa.get("spec", {}).get("metrics") or []:
        if sm.get("type") == "Pods":
            return ((sm.get("pods") or {}).get("metric") or {}).get("name") or ""
    return ""


def hpa_targets(hpa: dict[str, Any]) -> str:
    spec_metrics = hpa.get("spec", {}).get("metrics") or []
    current = hpa.get("status", {}).get("currentMetrics") or []
    parts: list[str] = []
    for i, sm in enumerate(spec_metrics):
        if sm.get("type") != "Pods":
            continue
        name = ((sm.get("pods") or {}).get("metric") or {}).get("name") or ""
        kind = metric_kind(name)
        target = (sm.get("pods") or {}).get("target") or {}
        tgt_raw = target.get("averageValue") or target.get("value")
        cm = current[i] if i < len(current) else {}
        cur = (cm.get("pods") or {}).get("current") or {}
        cur_raw = cur.get("averageValue") or cur.get("value")
        if kind == "gpu_utilization":
            parts.append(f"{fmt_pct(qty(cur_raw))}/{fmt_pct(qty(tgt_raw))}")
        elif kind == "latency":
            tgt_ms = qty(tgt_raw)
            parts.append(
                f"{fmt_ms(qty(cur_raw))}/{fmt_ms(3000.0 if tgt_ms is None else tgt_ms)}"
            )
        else:
            cur_v, tgt_v = qty(cur_raw), qty(tgt_raw)
            cur_s = "?" if cur_v is None else f"{cur_v:g}"
            tgt_s = "?" if tgt_v is None else f"{tgt_v:g}"
            parts.append(f"{cur_s}/{tgt_s}")
    return " ".join(parts) if parts else "<unknown>"


def snapshot_from_hpa_objects(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for hpa in items:
        meta = hpa.get("metadata") or {}
        spec = hpa.get("spec") or {}
        status = hpa.get("status") or {}
        rows.append(
            {
                "namespace": meta.get("namespace") or "",
                "name": meta.get("name") or "",
                "targets": hpa_targets(hpa),
                "minReplicas": spec.get("minReplicas", ""),
                "maxReplicas": spec.get("maxReplicas", ""),
                "replicas": status.get("currentReplicas", ""),
                "age": age(meta.get("creationTimestamp")),
                "metric_kind": metric_kind(hpa_metric_name(hpa)),
            }
        )
    return rows


def snapshot_from_pod_objects(
    items: list[dict[str, Any]], gpu_util: dict[str, str]
) -> list[dict[str, Any]]:
    rows = []
    for pod in sorted(items, key=lambda p: (p.get("metadata") or {}).get("name") or ""):
        meta = pod.get("metadata") or {}
        status = pod.get("status") or {}
        name = meta.get("name") or ""
        containers = status.get("containerStatuses") or []
        ready = sum(1 for c in containers if c.get("ready"))
        total = len(containers)
        rows.append(
            {
                "namespace": meta.get("namespace") or "",
                "name": name,
                "ready": f"{ready}/{total}" if total else "?",
                "status": status.get("phase") or "?",
                "restarts": sum((c.get("restartCount") or 0) for c in containers),
                "gpu_util": gpu_util.get(name, "<unknown>"),
                "age": age(meta.get("creationTimestamp")),
            }
        )
    return rows


def format_cluster(snapshot: dict[str, Any]) -> str:
    lines: list[str] = []
    hpas = list(snapshot.get("hpas") or [])
    pods = list(snapshot.get("pods") or [])
    gpus = list(snapshot.get("gpus") or [])

    if hpas:
        kind = hpas[0].get("metric_kind") or "gpu_utilization"
        if kind == "latency":
            subtitle = "HPA — LLM latency (avg per pod): current / target (ms)"
            metric_col = "LATENCY ms"
        else:
            subtitle = "HPA — GPU utilization (avg per pod): current / target"
            metric_col = "GPU UTIL %"
        lines.append(subtitle)
        lines.append(
            f"{'NAME':<{NAME_W}} {metric_col:<12} "
            f"{'MINPODS':<8} {'MAXPODS':<8} {'REPLICAS':<10} AGE"
        )
        for hpa in hpas:
            label = display_name(str(hpa.get("name") or ""), str(hpa.get("namespace") or ""))
            lines.append(
                f"{label:<{NAME_W}} "
                f"{str(hpa.get('targets') or '?'):<12} "
                f"{str(hpa.get('minReplicas', '')):<8} "
                f"{str(hpa.get('maxReplicas', '')):<8} "
                f"{str(hpa.get('replicas', '')):<10} "
                f"{hpa.get('age') or '?'}"
            )
        lines.append("")

    lines.append("Pods")
    if not pods:
        lines.append("  (no GPU pods)")
    else:
        lines.append(
            f"{'NAME':<{NAME_W}} {'READY':<7} "
            f"{'STATUS':<11} {'GPU UTIL':<10} AGE"
        )
        for pod in pods:
            label = display_name(str(pod.get("name") or ""), str(pod.get("namespace") or ""))
            lines.append(
                f"{label:<{NAME_W}} "
                f"{str(pod.get('ready') or '?'):<7} "
                f"{str(pod.get('status') or '?'):<11} "
                f"{str(pod.get('gpu_util') or '<'):<10} "
                f"{pod.get('age') or '?'}"
            )
        lines.append("")

    lines.append("GPUs")
    if not gpus:
        lines.append("  (DCGM GPU index map unavailable)")
    else:
        lines.append(f"{'GPU':<6} {'NODE':<12} {'UTIL':<8} NAME")
        for gpu in gpus:
            label = display_name(str(gpu.get("pod") or ""), str(gpu.get("namespace") or ""))
            index = str(gpu.get("index") if gpu.get("index") is not None else "?")
            lines.append(
                f"GPU {index:<2} {str(gpu.get('node') or '?'):<12} "
                f"{str(gpu.get('util') or '?'):<8} {label}"
            )
    return "\n".join(lines) + "\n"


def _kubectl(args: list[str], timeout: int = 8) -> Any:
    try:
        raw = subprocess.check_output(
            ["kubectl", *args],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
        )
        return json.loads(raw) if raw.strip().startswith("{") or raw.strip().startswith("[") else raw
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        FileNotFoundError,
        OSError,
    ):
        return None


def _gpu_chart_hpas(namespace: str) -> list[dict[str, Any]]:
    if namespace:
        data = _kubectl(["get", "hpa", "-n", namespace, "-o", "json"])
        items = (data or {}).get("items") or [] if isinstance(data, dict) else []
        return [h for h in items if GPU_NS_RE.match(namespace)]
    data = _kubectl(["get", "hpa", "-A", "-o", "json"])
    items = (data or {}).get("items") or [] if isinstance(data, dict) else []
    return [
        h
        for h in items
        if GPU_NS_RE.match(((h.get("metadata") or {}).get("namespace") or ""))
    ]


def _gpu_chart_pods(namespaces: list[str]) -> list[dict[str, Any]]:
    data = _kubectl(
        [
            "get",
            "pods",
            "-A",
            "-l",
            "app.kubernetes.io/name=nemoclaw-gpu,component=gpu-metrics-proxy",
            "-o",
            "json",
        ]
    )
    items = (data or {}).get("items") or [] if isinstance(data, dict) else []
    wanted = set(namespaces)
    return [
        p
        for p in items
        if ((p.get("metadata") or {}).get("namespace") or "") in wanted
    ]


def _pod_gpu_util(namespaces: list[str]) -> dict[str, str]:
    gpu: dict[str, str] = {}
    for ns in namespaces:
        data = _kubectl(
            [
                "get",
                "--raw",
                f"/apis/custom.metrics.k8s.io/v1beta1/namespaces/{ns}/pods/*/gpu_utilization_percent",
            ]
        )
        if not isinstance(data, dict):
            continue
        for item in data.get("items") or []:
            pod = ((item.get("describedObject") or {}).get("name") or "")
            if pod:
                gpu[pod] = fmt_pct(qty(item.get("value")))
    return gpu


def _prometheus_proxy_paths() -> list[str]:
    monitoring_ns = os.environ.get("MONITORING_NS") or ""
    release = os.environ.get("PROM_RELEASE") or "kube-prometheus-stack"
    svc = os.environ.get("PROM_SERVICE") or f"{release}-prometheus"
    namespaces = [monitoring_ns] if monitoring_ns else ["prometheus", "monitoring"]
    paths = []
    for ns in namespaces:
        if not ns:
            continue
        paths.append(
            f"/api/v1/namespaces/{ns}/services/{svc}:9090/proxy/api/v1/query"
        )
    return paths


def _gpu_map(namespaces: list[str]) -> list[dict[str, Any]]:
    query = 'DCGM_FI_DEV_GPU_UTIL{exported_pod!=""}'
    wanted = set(namespaces)
    payload = None
    for path in _prometheus_proxy_paths():
        data = _kubectl(["get", "--raw", f"{path}?query={quote(query)}"], timeout=12)
        if isinstance(data, dict) and data.get("status") == "success":
            payload = data
            break
    if not isinstance(payload, dict):
        return []
    rows: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for item in ((payload.get("data") or {}).get("result") or []):
        metric = item.get("metric") or {}
        ns = metric.get("exported_namespace") or ""
        pod = metric.get("exported_pod") or ""
        if ns not in wanted or not pod:
            continue
        index = str(metric.get("gpu") if metric.get("gpu") is not None else "")
        node = metric.get("kubernetes_node") or metric.get("Hostname") or ""
        key = (index, node, pod)
        if key in seen:
            continue
        seen.add(key)
        value = (item.get("value") or [None, None])[1]
        try:
            util = fmt_pct(float(value)) if value is not None else "?"
        except (TypeError, ValueError):
            util = str(value) if value is not None else "?"
        rows.append(
            {
                "index": index,
                "node": node,
                "namespace": ns,
                "pod": pod,
                "util": util,
            }
        )
    rows.sort(key=lambda r: (int(r["index"]) if str(r["index"]).isdigit() else 99, r["node"], r["pod"]))
    return rows


def live_snapshot(namespace: str = "") -> dict[str, Any]:
    hpas = _gpu_chart_hpas(namespace)
    hpa_rows = snapshot_from_hpa_objects(hpas)
    namespaces = []
    for row in hpa_rows:
        ns = str(row.get("namespace") or "")
        if ns and ns not in namespaces:
            namespaces.append(ns)
    if namespace and namespace not in namespaces:
        namespaces.insert(0, namespace)
    pods = _gpu_chart_pods(namespaces)
    return {
        "hpas": hpa_rows,
        "pods": snapshot_from_pod_objects(pods, _pod_gpu_util(namespaces)),
        "gpus": _gpu_map(namespaces),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Print GPU-chart HPA, pods, and GPU index as hermes-vllm / openclaw-ollama."
    )
    parser.add_argument("--live", action="store_true", help="Read the cluster through kubectl")
    parser.add_argument("-n", "--namespace", default="", help="One GPU-chart namespace; default is all nemoclaw-gpu*")
    args = parser.parse_args(argv)
    if not args.live:
        parser.error("pass --live, or import format_cluster from a test")
    sys.stdout.write(format_cluster(live_snapshot(args.namespace)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
