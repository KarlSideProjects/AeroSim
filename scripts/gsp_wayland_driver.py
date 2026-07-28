#!/usr/bin/env python3
"""Small real-compositor driver for the provisional GSP Wayland probe.

It deliberately requires caller-supplied screen points. Wayland does not expose
portable window IDs here, so guessing coordinates would turn focus evidence into
an intent-only claim.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


class DriverUnavailable(RuntimeError):
    pass


def read_stages(path: Path) -> list[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    stages = payload.get("stages", [])
    if isinstance(stages, list):
        return [str(stage) for stage in stages]
    current = payload.get("stage", "")
    return [str(current)] if current else []


def wait_for_stage(path: Path, stage: str, deadline: float) -> None:
    while time.monotonic() < deadline:
        if stage in read_stages(path):
            return
        time.sleep(0.05)
    raise DriverUnavailable(f"timed out waiting for stage {stage}")


def point_from_env(name: str) -> tuple[int, int]:
    value = os.environ.get(name, "")
    try:
        x, y = (int(part.strip()) for part in value.split(",", 1))
    except (TypeError, ValueError):
        raise DriverUnavailable(f"{name} must be supplied as x,y") from None
    if x < 0 or y < 0:
        raise DriverUnavailable(f"{name} must contain non-negative screen coordinates")
    return x, y


def run_input(point: tuple[int, int]) -> None:
    if shutil.which("ydotool") is None:
        raise DriverUnavailable("ydotool is unavailable")
    x, y = point
    subprocess.run(
        ["ydotool", "mousemove", "--absolute", "-x", str(x), "-y", str(y)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(
        ["ydotool", "click", "0xC0"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def screenshot(path: Path) -> None:
    if shutil.which("grim") is None:
        raise DriverUnavailable("grim is unavailable")
    result = subprocess.run(["grim", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0 or not path.is_file() or path.stat().st_size == 0:
        raise DriverUnavailable(f"grim failed for {path}: {result.stderr.strip()}")


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stage_path = args.out_dir / "stage.json"
    unavailable_path = args.out_dir / "external-unavailable.json"
    browser_click_sent_path = args.out_dir / "browser-click-sent.json"
    evidence_path = args.out_dir / "external-evidence.json"
    deadline = time.monotonic() + 45.0
    evidence: dict = {"driver": "ydotool+grim", "actions": [], "screenshots": []}
    try:
        game_point = point_from_env("AEROSIM_GSP_GAME_POINT")
        browser_point = point_from_env("AEROSIM_GSP_BROWSER_POINT")
        wait_for_stage(stage_path, "await_initial_pointer", deadline)
        run_input(game_point)
        screenshot(args.out_dir / "00_initial_pointer_game.png")
        evidence["actions"].append("clicked_game_initial")
        evidence["screenshots"].append("00_initial_pointer_game.png")

        wait_for_stage(stage_path, "captured", deadline)
        screenshot(args.out_dir / "01_captured_game.png")
        evidence["screenshots"].append("01_captured_game.png")

        wait_for_stage(stage_path, "panel_open_requested", deadline)
        screenshot(args.out_dir / "02_panel_open_requested.png")
        evidence["screenshots"].append("02_panel_open_requested.png")

        run_input(browser_point)
        write_json(browser_click_sent_path, {"event": "browser_click_sent", "time": time.time()})
        screenshot(args.out_dir / "03_browser_clicked.png")
        evidence["actions"].append("clicked_browser_coordinate")
        evidence["screenshots"].append("03_browser_clicked.png")

        wait_for_stage(stage_path, "panel_focus_observed", deadline)

        wait_for_stage(stage_path, "await_game_focus", deadline)
        run_input(game_point)
        screenshot(args.out_dir / "04_game_clicked.png")
        evidence["actions"].append("clicked_game_return")
        evidence["screenshots"].append("04_game_clicked.png")

        wait_for_stage(stage_path, "recaptured", deadline)
        screenshot(args.out_dir / "05_recaptured_game.png")
        evidence["screenshots"].append("05_recaptured_game.png")
        evidence["external_focus_actions_completed"] = True
        write_json(evidence_path, evidence)
        return 0
    except (DriverUnavailable, subprocess.CalledProcessError) as error:
        write_json(unavailable_path, {"status": "not_qualified", "reason": str(error)})
        evidence["status"] = "not_qualified"
        evidence["reason"] = str(error)
        write_json(evidence_path, evidence)
        return 2


if __name__ == "__main__":
    sys.exit(main())
