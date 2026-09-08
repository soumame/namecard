#!/usr/bin/env python3
"""Generate an xctestrun from existing Simulator products; never build or run them."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys


def read_bundle(bundle):
    info_path = bundle / "Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    if info.get("DTPlatformName") != "iphonesimulator":
        raise ValueError(f"Not an iOS Simulator product: {bundle}")
    for key in ("CFBundleExecutable", "CFBundleIdentifier"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError(f"Missing {key}: {info_path}")
    executable = bundle / info["CFBundleExecutable"]
    if executable.parent != bundle or not executable.is_file():
        raise ValueError(f"Built executable not found: {executable}")
    return info


def make_manifest(products, ui):
    app = products / "Namecard.app"
    read_bundle(app)
    target_name = "NamecardUITests" if ui else "NamecardTests"
    host = products / "NamecardUITests-Runner.app" if ui else app
    host_info = read_bundle(host)
    test_bundle = host / "PlugIns" / f"{target_name}.xctest"
    test_info = read_bundle(test_bundle)

    # xcrun respects both xcode-select and an explicit DEVELOPER_DIR. Resolve
    # paths at generation time instead of assuming /Applications/Xcode.app.
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"],
        text=True, timeout=20,
    ).strip())
    frameworks = platform / "Developer/Library/Frameworks"
    libraries = platform / "Developer/usr/lib"
    if not (frameworks / "XCTest.framework").is_dir() or not libraries.is_dir():
        raise ValueError(f"Selected Xcode lacks Simulator XCTest support: {platform}")
    environment = {
        "DYLD_FRAMEWORK_PATH": f"{products}:{frameworks}",
        "DYLD_LIBRARY_PATH": f"{products}:{libraries}",
    }
    if not ui:
        injector = libraries / "libXCTestBundleInject.dylib"
        if not injector.is_file():
            raise ValueError(f"XCTest injection library not found: {injector}")
        environment["DYLD_INSERT_LIBRARIES"] = str(injector)
        environment["XCInjectBundleInto"] = f"__TESTHOST__/{host_info['CFBundleExecutable']}"

    target = {
        "BlueprintName": target_name,
        "ProductModuleName": test_info["CFBundleExecutable"],
        "IsUITestBundle": ui,
        "IsAppHostedTestBundle": not ui,
        "TestBundlePath": str(test_bundle),
        "TestHostPath": str(host),
        "TestHostBundleIdentifier": host_info["CFBundleIdentifier"],
        "TestingEnvironmentVariables": environment,
        "ParallelizationEnabled": False,
    }
    if ui:
        target.update({
            "UITargetAppPath": str(app),
            "DependentProductPaths": [str(app), str(host), str(test_bundle)],
            "TestLanguage": "ja",
            "TestRegion": "JP",
            "SystemAttachmentLifetime": "keepAlways",
            "UserAttachmentLifetime": "keepAlways",
        })
    return {
        "TestPlan": {"Name": target_name, "IsDefault": True},
        "TestConfigurations": [{
            "Name": products.name,
            "IsEnabled": True,
            "TestTargets": [target],
        }],
        "__xctestrun_metadata__": {"FormatVersion": 2},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True, type=Path,
                        help="Existing Debug-iphonesimulator build products directory")
    parser.add_argument("--output", required=True, type=Path,
                        help="Destination .xctestrun file")
    parser.add_argument("--ui", action="store_true",
                        help="Select NamecardUITests instead of app unit tests")
    args = parser.parse_args()
    products = args.products.expanduser().resolve()
    output = args.output.expanduser().resolve()
    try:
        manifest = make_manifest(products, args.ui)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(plistlib.dumps(manifest, fmt=plistlib.FMT_XML))
    except (OSError, ValueError, plistlib.InvalidFileException,
            subprocess.SubprocessError) as error:
        print(f"Cannot generate Simulator test manifest: {error}", file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
