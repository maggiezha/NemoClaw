#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""
OpenClaw + Ollama e2e: N end users send prompts into N CPU OpenClaw sandboxes.
Default N is E2E_USERS=10 (one sandbox per user). GPU inference is Ollama.

Each user talks only to its sandbox's already-running OpenClaw agent (:18789).
Do not spawn `openclaw agent -m` (that starts a second Node CLI).

    openshell sandbox exec → chat.send on ws://127.0.0.1:18789/ws

The agent then calls https://inference.local (Envoy → Ollama HPA).
This is not files/load-generator.ts (that Job POSTs chat/completions at pod IPs).
This is not in-sandbox curl to inference.local.
Hermes + vLLM is a later e2e and is not this script.

Usage:
    E2E_USERS=10 python3 scripts/e2e-openclaw-ollama-load-test.py
    python3 scripts/e2e-openclaw-ollama-load-test.py --users 10
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import csv
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

FALLBACK_RE = re.compile(
    r"EMBEDDED FALLBACK|\[agent/embedded\]|fallbackFrom[\": ]+gateway|transport[\": ]+embedded",
    re.IGNORECASE,
)

PROMPTS = [
    "In one sentence, what is an AI agent sandbox?",
    "Say OK in one word.",
    "Name one reason to isolate an agent from the GPU node.",
    "Reply with a single short greeting.",
    "In one sentence, what does GPU autoscaling do?",
]


HELPER_PATH = Path(__file__).resolve().parent.parent / "files" / "openclaw-e2e-ws-prompt.py"
_HELPER_B64 = ""


def sandbox_name(prefix: str, user_id: int) -> str:
    return f"{prefix}{user_id:04d}"


def helper_b64() -> str:
    global _HELPER_B64
    if not _HELPER_B64:
        _HELPER_B64 = base64.b64encode(HELPER_PATH.read_bytes()).decode("ascii")
    return _HELPER_B64


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


async def terminate_proc(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=20)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


async def send_user_query(
    sandbox: str, prompt: str, timeout_sec: int, session_key: str
) -> tuple[bool, str]:
    """Send one prompt to the already-running OpenClaw agent. No extra Node CLI."""
    openshell = shutil.which("openshell")
    if not openshell:
        return False, "openshell is not on PATH"
    if not HELPER_PATH.is_file():
        return False, f"missing {HELPER_PATH}"
    proc = await asyncio.create_subprocess_exec(
        openshell,
        "sandbox",
        "exec",
        "-n",
        sandbox,
        "--no-tty",
        "--",
        "bash",
        "-c",
        (
            "set -euo pipefail; "
            # OpenShell injects the sandbox-create token; nemoclaw-start rotates
            # gateway.auth.token. Prefer json in the helper. Drop both URL and
            # token before proxy-env so a stale env token cannot win.
            "unset OPENCLAW_GATEWAY_URL OPENCLAW_GATEWAY_TOKEN || true; "
            ". /tmp/nemoclaw-proxy-env.sh; "
            "unset OPENCLAW_GATEWAY_TOKEN || true; "
            "export E2E_PROMPT_TIMEOUT_SEC=\"$3\" E2E_SESSION_KEY=\"$4\"; "
            "echo \"$1\" | base64 -d | python3 - \"$2\""
        ),
        "bash",
        helper_b64(),
        prompt,
        str(timeout_sec),
        session_key,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=timeout_sec + 30)
    except asyncio.TimeoutError:
        await terminate_proc(proc)
        return False, f"timed out after {timeout_sec}s"
    stdout = stdout_b.decode("utf-8", errors="replace").strip()
    stderr = stderr_b.decode("utf-8", errors="replace").strip()
    combined = f"{stdout}\n{stderr}"
    if proc.returncode != 0:
        return False, stderr or stdout or f"exit {proc.returncode}"
    if FALLBACK_RE.search(combined):
        return False, "OpenClaw used embedded fallback instead of the managed gateway"
    if not stdout:
        return False, "empty OpenClaw response"
    if "LLM request failed" in combined or "network connection error" in combined:
        return False, stdout or stderr
    return True, stdout


async def simulate_user(
    user_id: int,
    prefix: str,
    inflight: int,
    duration_sec: int,
    timeout_sec: int,
    stop_event: asyncio.Event,
    log_path: Path,
) -> dict[str, object]:
    sandbox = sandbox_name(prefix, user_id)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    ok = 0
    err = 0
    started = time.monotonic()
    end = started + duration_sec
    turn = 0
    log_handle = log_path.open("w")

    async def one_turn(turn_id: int) -> None:
        nonlocal ok, err
        prompt = PROMPTS[(user_id + turn_id) % len(PROMPTS)]
        success, detail = await send_user_query(
            sandbox,
            prompt,
            timeout_sec,
            f"agent:main:{sandbox}:t{turn_id}",
        )
        if success:
            ok += 1
            log_handle.write(f"ok turn={turn_id}\n")
        else:
            err += 1
            log_handle.write(f"err turn={turn_id} {detail}\n")
            print(f"[user {user_id} {sandbox}] turn {turn_id} error: {detail}", file=sys.stderr)
        log_handle.flush()

    pending: set[asyncio.Task[None]] = set()
    try:
        while time.monotonic() < end and not stop_event.is_set():
            while len(pending) < inflight and time.monotonic() < end and not stop_event.is_set():
                pending.add(asyncio.create_task(one_turn(turn)))
                turn += 1
            if not pending:
                break
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                await task
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
    finally:
        log_handle.write(f"ok={ok} err={err}\n")
        log_handle.close()
    return {
        "user_id": user_id,
        "sandbox": sandbox,
        "ok": ok,
        "err": err,
        "turns": turn,
        "duration": time.monotonic() - started,
        "log": str(log_path),
    }


async def run_test(args: argparse.Namespace) -> int:
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir = output_dir / "sandbox-logs"
    stop_load = asyncio.Event()
    hpa_rows: list[dict[str, object]] = []
    max_replicas = 0
    reached_target = False
    hold_started: float | None = None

    print("=" * 70)
    print("  E2E test: OpenClaw + Ollama")
    print(f"  {args.users} end users send requests to {args.users} OpenClaw agents")
    print(f"  {args.users} agents run in {args.users} OpenShell sandboxes on CPU")
    print(f"  LLM (Ollama {args.model}) runs on GPUs")
    print("  When end-user demand increases, GPU HPA scales Ollama from 1 to 8 GPUs")
    print(f"  Sandboxes: {args.prefix}0000 … {args.prefix}{args.users - 1:04d}")
    print("  Each user prompts the already-running OpenClaw agent on :18789")
    print("  Path: end user → CPU agent/sandbox → https://inference.local → Envoy → GPU Ollama HPA")
    print("  One OpenShell gateway for all sandboxes. Not a second Node CLI, not load-generator.ts.")
    print(f"  Concurrent prompts per user: {args.inflight_per_user}")
    print(f"  GPU inference model={args.model}  HPA {args.hpa_namespace}/{args.hpa_name}")
    print(f"  duration≤{args.duration}s  target replicas={args.target_pods}")
    print("=" * 70)

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
                    print(
                        f"[hpa] end-user demand scaled GPUs to {args.target_pods}; "
                        f"holding {args.hold_sec}s then stopping user queries"
                    )
                if time.monotonic() - hold_started >= args.hold_sec:
                    reached_target = True
                    stop_load.set()
                    return
            try:
                await asyncio.wait_for(stop_load.wait(), timeout=args.hpa_poll_sec)
            except asyncio.TimeoutError:
                continue

    poll_task = asyncio.create_task(poll_hpa())
    user_tasks = [
        asyncio.create_task(
            simulate_user(
                user_id=i,
                prefix=args.prefix,
                inflight=args.inflight_per_user,
                duration_sec=args.duration,
                timeout_sec=args.timeout,
                stop_event=stop_load,
                log_path=logs_dir / f"{sandbox_name(args.prefix, i)}.log",
            )
        )
        for i in range(args.users)
    ]

    deadline = time.monotonic() + args.duration + 30
    while True:
        if stop_load.is_set() or time.monotonic() >= deadline or all(t.done() for t in user_tasks):
            if time.monotonic() >= deadline and not stop_load.is_set():
                print("[load] duration elapsed; stopping user queries", file=sys.stderr)
            stop_load.set()
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
    await poll_task

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
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "path": "user -> OpenClaw sandbox -> inference.local -> Envoy -> Ollama HPA",
        "users": args.users,
        "target_pods": args.target_pods,
        "hpa_max_replicas": max_replicas,
        "reached_target": reached_target or max_replicas >= args.target_pods,
        "scale_down_ok": scale_down_ok,
        "successful_queries": successful,
        "failed_queries": failed,
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
        f"user→sandbox queries ok={successful} err={failed}"
    )
    if successful < 1:
        print("No successful user→sandbox OpenClaw queries.", file=sys.stderr)
        return 1
    if not summary["reached_target"]:
        print(
            f"HPA did not scale to {args.target_pods} replicas under user→sandbox load.",
            file=sys.stderr,
        )
        return 1
    if not scale_down_ok:
        print("HPA did not scale down to 1 replica after user queries stopped.", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="OpenClaw + Ollama e2e: N users send OpenClaw prompts into N sandboxes (not Envoy-direct); default E2E_USERS=10"
    )
    parser.add_argument("--users", type=int, default=int(os.environ.get("E2E_USERS", "10")))
    parser.add_argument("--prefix", default=os.environ.get("SANDBOX_PREFIX", "openclaw-ollama-e2e-"))
    parser.add_argument("--output", default=os.environ.get("E2E_OUTPUT_DIR", "./e2e-results/openclaw-ollama"))
    parser.add_argument("--model", default=os.environ.get("INFERENCE_MODEL", "llama3.2:3b"))
    parser.add_argument("--duration", type=int, default=int(os.environ.get("DURATION_SEC", "900")))
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("E2E_PROMPT_TIMEOUT_SEC", "180")))
    parser.add_argument(
        "--inflight-per-user",
        type=int,
        default=int(os.environ.get("E2E_INFLIGHT_PER_USER", "1")),
        help="Concurrent prompts each user sends to their already-running agent (keep 1 to stay light)",
    )
    parser.add_argument("--target-pods", type=int, default=int(os.environ.get("TARGET_PODS", "8")))
    parser.add_argument("--hold-sec", type=float, default=float(os.environ.get("MAX_REPLICAS_HOLD_SEC", "0")))
    parser.add_argument("--hpa-namespace", default=os.environ.get("NAMESPACE", "nemoclaw-gpu"))
    parser.add_argument("--hpa-name", default=os.environ.get("HPA_NAME", "nemoclaw-gpu-metrics-proxy"))
    parser.add_argument("--hpa-poll-sec", type=float, default=float(os.environ.get("SCALE_UP_POLL_SEC", "10")))
    parser.add_argument("--scale-down-wait-loops", type=int, default=int(os.environ.get("SCALE_DOWN_WAIT_LOOPS", "40")))
    args = parser.parse_args()
    if args.users < 1 or args.inflight_per_user < 1:
        print("--users and --inflight-per-user must be >= 1", file=sys.stderr)
        return 2
    return asyncio.run(run_test(args))


if __name__ == "__main__":
    sys.exit(main())
