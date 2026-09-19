#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""
20-user OpenClaw sandbox saturator for the same 8×H100 GPU HPA backend.

Each simulated end user owns one CPU-only sandbox. That sandbox sends concurrent
chat completions to https://inference.local (Envoy → GPU replicas). Combined
in-flight matches the 8×H100 knobs (320×2 per GPU, cap 640/pod) split across
the users — this replaces files/load-generator.ts for the multi-sandbox e2e.

Usage:
    python3 scripts/e2e-openclaw-load-test.py --users 20
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PROMPTS = [
    "In one sentence, what is an AI agent sandbox?",
    "Say OK in one word.",
    "Name one reason to isolate an agent from the GPU node.",
    "Reply with a single short greeting.",
    "In one sentence, what does GPU autoscaling do?",
]


def sandbox_name(prefix: str, user_id: int) -> str:
    return f"{prefix}{user_id:04d}"


def read_hpa(namespace: str, name: str) -> tuple[int, int]:
    try:
        raw = subprocess.check_output(
            [
                "kubectl",
                "get",
                "hpa",
                name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.status.currentReplicas} {.status.desiredReplicas}",
            ],
            text=True,
            timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return 0, 0
    parts = raw.split()
    current = int(parts[0]) if parts and parts[0].isdigit() else 0
    desired = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return current, desired


def load_saturate_script(script_path: Path) -> str:
    text = script_path.read_text()
    if "sandbox-saturate" not in text:
        raise RuntimeError(f"{script_path} does not look like the sandbox saturator")
    return text


def parse_ok_err(log_path: Path) -> tuple[int, int]:
    ok = err = 0
    try:
        tail = log_path.read_text(errors="replace").strip().splitlines()
    except OSError:
        return 0, 0
    for line in reversed(tail):
        if "ok=" not in line or "err=" not in line:
            continue
        for part in line.split():
            if part.startswith("ok="):
                ok = int(part.split("=", 1)[1])
            if part.startswith("err="):
                err = int(part.split("=", 1)[1])
        break
    return ok, err


async def terminate_proc(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=20)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


async def run_user_sandbox(
    user_id: int,
    prefix: str,
    script_b64: str,
    inflight: int,
    max_inflight: int,
    duration_sec: int,
    max_tokens: int,
    model: str,
    log_path: Path,
    procs: list[asyncio.subprocess.Process],
) -> dict[str, object]:
    openshell = shutil.which("openshell")
    if not openshell:
        raise RuntimeError("openshell is not on PATH")
    name = sandbox_name(prefix, user_id)
    prompt = PROMPTS[user_id % len(PROMPTS)].replace("'", "")
    remote = (
        f"echo {script_b64} | base64 -d | "
        f"INFLIGHT={inflight} MAX_INFLIGHT={max_inflight} "
        f"DURATION_SEC={duration_sec} MAX_TOKENS={max_tokens} "
        f"INFERENCE_MODEL={model} PROMPT='{prompt}' bash"
    )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w")
    started = time.monotonic()
    proc = await asyncio.create_subprocess_exec(
        openshell,
        "sandbox",
        "exec",
        "-n",
        name,
        "--no-tty",
        "--",
        "bash",
        "-c",
        remote,
        stdout=log_handle,
        stderr=asyncio.subprocess.STDOUT,
    )
    procs.append(proc)
    try:
        rc = await proc.wait()
    except asyncio.CancelledError:
        await terminate_proc(proc)
        rc = proc.returncode if proc.returncode is not None else -15
    finally:
        log_handle.close()
    elapsed = time.monotonic() - started
    ok, err = parse_ok_err(log_path)
    return {
        "user_id": user_id,
        "sandbox": name,
        "returncode": rc,
        "duration": elapsed,
        "ok": ok,
        "err": err,
        "log": str(log_path),
    }


async def run_test(args: argparse.Namespace) -> int:
    script_path = Path(args.saturate_script)
    script_b64 = base64.b64encode(load_saturate_script(script_path).encode()).decode("ascii")
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir = output_dir / "sandbox-logs"

    per_pod_peak = min(args.inflight_per_gpu * args.load_multiplier, args.max_inflight_per_pod)
    max_inflight = max(1, (per_pod_peak * args.target_pods + args.users - 1) // args.users)
    inflight = max(1, min(args.bootstrap_inflight, max_inflight))

    print("=" * 70)
    print("  OpenClaw 20-user sandbox saturator (8×H100 GPU HPA backend)")
    print(f"  Users/sandboxes: {args.users}  prefix={args.prefix}")
    print(f"  Per sandbox inflight {inflight} → {max_inflight} (cluster cap {per_pod_peak}/GPU pod × {args.target_pods})")
    print(f"  Tokens={args.max_tokens}  duration≤{args.duration}s  model={args.model}")
    print(f"  Path: user → sandbox → inference.local → Envoy → GPU HPA")
    print("=" * 70)

    stop_load = asyncio.Event()
    hpa_rows: list[dict[str, object]] = []
    max_replicas = 0
    reached_target = False
    hold_started: float | None = None

    async def poll_hpa() -> None:
        nonlocal max_replicas, reached_target, hold_started
        while not stop_load.is_set():
            current, desired = await asyncio.to_thread(read_hpa, args.hpa_namespace, args.hpa_name)
            max_replicas = max(max_replicas, current, desired)
            hpa_rows.append(
                {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "current_replicas": current,
                    "desired_replicas": desired,
                }
            )
            print(f"[hpa] {args.hpa_namespace}/{args.hpa_name} current={current} desired={desired}")
            if current >= args.target_pods:
                if hold_started is None:
                    hold_started = time.monotonic()
                    print(f"[hpa] reached {args.target_pods} replicas; holding {args.hold_sec}s then stopping sandbox load")
                if time.monotonic() - hold_started >= args.hold_sec:
                    reached_target = True
                    stop_load.set()
                    return
            try:
                await asyncio.wait_for(stop_load.wait(), timeout=args.hpa_poll_sec)
            except asyncio.TimeoutError:
                continue

    procs: list[asyncio.subprocess.Process] = []
    poll_task = asyncio.create_task(poll_hpa())
    user_tasks = [
        asyncio.create_task(
            run_user_sandbox(
                user_id=i,
                prefix=args.prefix,
                script_b64=script_b64,
                inflight=inflight,
                max_inflight=max_inflight,
                duration_sec=args.duration,
                max_tokens=args.max_tokens,
                model=args.model,
                log_path=logs_dir / f"{sandbox_name(args.prefix, i)}.log",
                procs=procs,
            )
        )
        for i in range(args.users)
    ]

    deadline = time.monotonic() + args.duration + 30
    load_stopped = False
    while True:
        if (stop_load.is_set() or time.monotonic() >= deadline) and not load_stopped:
            load_stopped = True
            if time.monotonic() >= deadline and not stop_load.is_set():
                print("[load] duration elapsed; stopping sandbox saturators", file=sys.stderr)
                stop_load.set()
            else:
                print("[load] stopping sandbox saturators")
            for proc in procs:
                await terminate_proc(proc)
            break
        if all(task.done() for task in user_tasks):
            break
        await asyncio.sleep(1)

    results = list(await asyncio.gather(*user_tasks, return_exceptions=True))
    normalized: list[dict[str, object]] = []
    for item in results:
        if isinstance(item, dict):
            normalized.append(item)
        else:
            normalized.append({"error": str(item), "ok": 0, "err": 1})
    results = normalized

    stop_load.set()
    await poll_task

    # Wait for scale-down after load stops.
    scale_down_ok = False
    for _ in range(args.scale_down_wait_loops):
        current, desired = await asyncio.to_thread(read_hpa, args.hpa_namespace, args.hpa_name)
        hpa_rows.append(
            {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "current_replicas": current,
                "desired_replicas": desired,
            }
        )
        print(f"[hpa] scale-down current={current} desired={desired}")
        if current <= 1:
            scale_down_ok = True
            break
        await asyncio.sleep(15)

    csv_path = output_dir / f"hpa_{args.users}users.csv"
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["timestamp", "current_replicas", "desired_replicas"])
        writer.writeheader()
        writer.writerows(hpa_rows)

    successful = sum(int(r.get("ok") or 0) for r in results)
    failed = sum(int(r.get("err") or 0) for r in results)
    if successful < 1:
        for result in results:
            log_file = result.get("log")
            if not log_file:
                continue
            ok, err = parse_ok_err(Path(str(log_file)))
            result["ok"] = ok
            result["err"] = err
        successful = sum(int(r.get("ok") or 0) for r in results)
        failed = sum(int(r.get("err") or 0) for r in results)
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "users": args.users,
        "target_pods": args.target_pods,
        "hpa_max_replicas": max_replicas,
        "reached_target": reached_target or max_replicas >= args.target_pods,
        "scale_down_ok": scale_down_ok,
        "successful_completions": successful,
        "failed_completions": failed,
        "results": results,
    }
    summary_path = output_dir / f"summary_{args.users}users.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Wrote {csv_path}")
    print(f"Wrote {summary_path}")
    print(
        f"HPA max={max_replicas} target={args.target_pods} "
        f"scale_up={'ok' if summary['reached_target'] else 'FAIL'} "
        f"scale_down={'ok' if scale_down_ok else 'FAIL'} "
        f"completions ok={successful} err={failed}"
    )
    if successful < 1:
        print("No successful in-sandbox completions.", file=sys.stderr)
        return 1
    if not summary["reached_target"]:
        print(f"HPA did not scale to {args.target_pods} replicas under sandbox load.", file=sys.stderr)
        return 1
    if not scale_down_ok:
        print("HPA did not scale down to 1 replica after sandbox load stopped.", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenClaw multi-sandbox GPU saturator")
    parser.add_argument("--users", type=int, default=int(os.environ.get("E2E_USERS", "20")))
    parser.add_argument("--prefix", default=os.environ.get("SANDBOX_PREFIX", "openclaw-e2e-"))
    parser.add_argument("--output", default=os.environ.get("E2E_OUTPUT_DIR", "./e2e-results"))
    parser.add_argument("--model", default=os.environ.get("INFERENCE_MODEL", "llama3.2:3b"))
    parser.add_argument("--duration", type=int, default=int(os.environ.get("DURATION_SEC", "900")))
    parser.add_argument("--max-tokens", type=int, default=int(os.environ.get("MAX_TOKENS", "128")))
    parser.add_argument("--inflight-per-gpu", type=int, default=int(os.environ.get("INFLIGHT_PER_GPU", "320")))
    parser.add_argument("--load-multiplier", type=int, default=int(os.environ.get("LOAD_MULTIPLIER", "2")))
    parser.add_argument("--max-inflight-per-pod", type=int, default=int(os.environ.get("MAX_INFLIGHT_PER_POD", "640")))
    parser.add_argument("--bootstrap-inflight", type=int, default=int(os.environ.get("E2E_BOOTSTRAP_INFLIGHT", "32")))
    parser.add_argument("--target-pods", type=int, default=int(os.environ.get("TARGET_PODS", "8")))
    parser.add_argument("--hold-sec", type=float, default=float(os.environ.get("MAX_REPLICAS_HOLD_SEC", "0")))
    parser.add_argument("--hpa-namespace", default=os.environ.get("NAMESPACE", "nemoclaw-gpu"))
    parser.add_argument("--hpa-name", default=os.environ.get("HPA_NAME", "nemoclaw-gpu-metrics-proxy"))
    parser.add_argument("--hpa-poll-sec", type=float, default=float(os.environ.get("SCALE_UP_POLL_SEC", "10")))
    parser.add_argument("--scale-down-wait-loops", type=int, default=int(os.environ.get("SCALE_DOWN_WAIT_LOOPS", "40")))
    default_script = Path(__file__).resolve().parent.parent / "files" / "e2e-sandbox-saturate.sh"
    parser.add_argument("--saturate-script", default=str(default_script))
    args = parser.parse_args()
    if args.users < 1:
        print("--users must be >= 1", file=sys.stderr)
        return 2
    return asyncio.run(run_test(args))


if __name__ == "__main__":
    sys.exit(main())
