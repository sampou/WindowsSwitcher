#!/usr/bin/env python3
"""只读采样已运行的 WindowsSwitcher：CPU、常驻内存和新增面板日志。

不发送键鼠事件、不修改配置、不启动或关闭应用。面板耗时只统计内部创建过程，
不包含热键等待、动画或屏幕呈现时间，不能作为完整按键响应延迟。
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import time


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="指定已运行的应用进程")
    parser.add_argument("--duration", type=float, default=60, help="采样秒数；长时运行可设 28800")
    parser.add_argument("--interval", type=float, default=2, help="采样间隔秒数")
    parser.add_argument("--scenario", default="observed", choices=["observed", "idle", "switching", "soak"])
    args = parser.parse_args()
    if args.duration <= 0 or args.interval < 0.1 or (args.pid is not None and args.pid <= 0):
        parser.error("duration 和 pid 必须为正，interval 至少 0.1 秒")
    if args.pid is None:
        result = subprocess.run(["pgrep", "-x", "WindowsSwitcher"], capture_output=True, text=True)
        pids = result.stdout.split()
        if len(pids) != 1:
            parser.error("需要唯一的运行中 WindowsSwitcher，或用 --pid 指定目标")
        args.pid = int(pids[0])

    log = Path.home() / "Library/Logs/WindowsSwitcher/operations.log"
    offset = log.stat().st_size if log.exists() else 0
    started = time.monotonic()
    samples = []
    while True:
        result = subprocess.run(["ps", "-p", str(args.pid), "-o", "%cpu=,rss="],
                                capture_output=True, text=True)
        fields = result.stdout.split()
        if result.returncode or len(fields) != 2:
            print(json.dumps({"status": "unavailable", "samples_collected": len(samples),
                              "reason": "进程已退出或采样权限不足"}, ensure_ascii=False))
            return 3
        samples.append((float(fields[0]), int(fields[1]) / 1024))
        remaining = args.duration - (time.monotonic() - started)
        if remaining <= 0:
            break
        time.sleep(min(args.interval, remaining))

    log_rotated = log.exists() and log.stat().st_size < offset
    if log.exists():
        with log.open("rb") as stream:
            stream.seek(0 if log_rotated else offset)
            new_log = stream.read().decode("utf-8", errors="replace")
    else:
        new_log = ""
    timings = [float(value) for value in re.findall(r"showSwitchPanel TOTAL: ([0-9.]+)ms", new_log)]
    cpu = [sample[0] for sample in samples]
    memory = [sample[1] for sample in samples]
    print(json.dumps({
        "status": "sampled", "pid": args.pid, "scenario": args.scenario,
        "duration_seconds": round(time.monotonic() - started, 2), "samples": len(samples),
        "cpu_percent": {"mean": round(statistics.mean(cpu), 2), "max": max(cpu)},
        "rss_mb": {"first": round(memory[0], 2), "last": round(memory[-1], 2),
                   "max": round(max(memory), 2), "delta": round(memory[-1] - memory[0], 2)},
        "panel_creation_ms": {"count": len(timings), "p50": percentile(timings, 0.5),
                              "p95": percentile(timings, 0.95)},
        "log_rotated": log_rotated,
        "limitations": "CPU 为 ps 采样值；RSS 不等同于完整内存占用；面板创建耗时不等同于按键到显示延迟。"
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
