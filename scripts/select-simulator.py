#!/usr/bin/env python3
"""Select the newest available iPhone runtime supported by the selected Xcode SDK."""

import json
import re
import sys


def version(value):
    if not re.fullmatch(r"\d+(?:[.-]\d+)*", value):
        raise ValueError(f"Invalid SDK/runtime version: {value}")
    parts = tuple(int(part) for part in re.split(r"[.-]", value))
    return parts + (0,) * (3 - len(parts))


def select_device(devices, sdk):
    supported = version(sdk)
    candidates = []
    for runtime, entries in devices.items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([\d-]+)", runtime)
        if not match:
            continue
        runtime_version = version(match[1])
        if runtime_version > supported:
            continue
        for device in entries:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                candidates.append((runtime_version, device.get("state") == "Booted", device["udid"]))
    if not candidates:
        raise ValueError(
            f"No available iPhone simulator compatible with iOS SDK {sdk}. "
            "Install a matching iOS runtime in Xcode Settings > Components, "
            "or set IOS_TEST_DESTINATION.")
    return max(candidates)[2]


if __name__ == "__main__":
    try:
        print("platform=iOS Simulator,id=" + select_device(json.load(sys.stdin)["devices"], sys.argv[1]))
    except (ValueError, KeyError, IndexError) as error:
        sys.exit(str(error))
