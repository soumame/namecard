#!/usr/bin/env python3
"""Check a built app/archive's distribution channel, resources and icon.

This is a local configuration check, not Apple's signature validation or App Review.
"""
import argparse
import json
from pathlib import Path
import plistlib


def check(app, channel):
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("NamecardDistributionChannel") != channel:
        raise ValueError(f"Expected {channel} build, found {info.get('NamecardDistributionChannel')!r}")
    expected_name = "Namecard Beta" if channel == "beta" else "Namecard"
    if info.get("CFBundleDisplayName") != expected_name:
        raise ValueError("Display name does not match the distribution channel")
    if not info.get("NFCReaderUsageDescription"):
        raise ValueError("NFC usage description is missing")
    if not info.get("CFBundleIcons") or not (app / "Assets.car").is_file():
        raise ValueError("Built app icon/assets are missing; do not use an asset-excluded build for distribution")
    with (app / "PrivacyInfo.xcprivacy").open("rb") as file:
        plistlib.load(file)
    with (app / "HardwareValidation.json").open() as file:
        hardware = json.load(file)
    if hardware.get("schemaVersion") != 1:
        raise ValueError("Hardware validation schema is invalid")
    if channel == "beta":
        with (app / "BetaDistribution.json").open() as file:
            beta = json.load(file)
        if (beta.get("schemaVersion") != 1 or type(beta.get("minimumIOSMajor")) is not int
                or beta["minimumIOSMajor"] < 17 or not isinstance(beta.get("deviceModels"), list)
                or not all(isinstance(model, str) and model.startswith("iPhone") for model in beta["deviceModels"])
                or not isinstance(beta.get("iOSMajorVersions"), list)
                or not all(type(version) is int and version >= beta["minimumIOSMajor"] for version in beta["iOSMajorVersions"])):
            raise ValueError("Beta audience configuration is invalid")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group(required=True)
    location.add_argument("--app", type=Path)
    location.add_argument("--archive", type=Path)
    parser.add_argument("--channel", choices=["beta", "app-store"], required=True)
    args = parser.parse_args()
    app = args.app or args.archive / "Products/Applications/Namecard.app"
    try:
        info = check(app, args.channel)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
    print(f"{args.channel}: {info['CFBundleIdentifier']} {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) — channel/resources OK")
    print("Signing, Apple validation and physical NFC tests are separate checks.")


if __name__ == "__main__":
    main()
