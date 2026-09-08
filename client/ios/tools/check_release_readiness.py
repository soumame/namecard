#!/usr/bin/env python3
"""A manual distribution gate. Never treat simulator tests as RF/EH validation."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "Namecard/Resources/HardwareValidation.json").read_text())
if manifest.get("schemaVersion") != 1:
    raise SystemExit("Unknown hardware validation schema")
devices = manifest.get("devices", [])
if len({d["model"] for d in devices}) < 2:
    raise SystemExit("Release blocked: record 10/10 physical-board results on at least two iPhone models; see docs/HARDWARE_VALIDATION.md.")
for device in devices:
    if device["completedRuns"] < 10 or device["iOSMajor"] < 17:
        raise SystemExit("Release blocked: insufficient validation")
    evidence = (root / device["evidence"]).resolve()
    if not evidence.is_relative_to(root) or not evidence.is_file():
        raise SystemExit("Release blocked: a local hardware evidence report is required")
    for route in ("normalSeconds", "batchSeconds", "legacySeconds"):
        value = device.get(route)
        if value is None and route != "normalSeconds":
            continue
        if not isinstance(value, (int, float)) or not 2.25 <= value < 50:
            raise SystemExit("Release blocked: refresh budgets must be measured and allow the five-second guard")
print("Hardware evidence present. Review the recordings and App Store checklist before distribution.")
