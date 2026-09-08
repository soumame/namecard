#!/usr/bin/env python3
"""Print an environment assignment for a bootable, installed iPhone simulator."""
import json
import subprocess

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
candidates = []
for runtime, entries in devices.items():
    marker = ".iOS-"
    if marker not in runtime:
        continue
    version = tuple(int(v) for v in runtime.split(marker)[1].split("-"))
    if version < (17,):
        continue
    candidates.extend((version, d["name"], d["udid"]) for d in entries if d["name"].startswith("iPhone") and d.get("isAvailable"))
if not candidates:
    raise SystemExit("Install an iOS 17+ simulator in Xcode Settings > Components.")
print("NAMECARD_SIMULATOR_ID=" + sorted(candidates, reverse=True)[0][2])
