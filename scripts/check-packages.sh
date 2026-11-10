#!/bin/bash
# The root Package.swift offers DictateKit to other apps through GitHub;
# Packages/DictateKit/Package.swift builds it for Dictate and its tests. They
# are kept by hand: this fails when they drift apart. Compared from SwiftPM's
# own reading of each manifest (dump-package), not their text:
# - the DictateKit target: dependencies, resources and Swift settings;
# - the package: tools version, platforms, default localization, products,
#   and every dependency's URL and version requirement;
# - the FluidAudio pin in both Package.resolved files.
#
#   scripts/check-packages.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
swift package dump-package --package-path . > "$ROOT/root.json"
swift package dump-package --package-path Packages/DictateKit > "$ROOT/kit.json"

python3 -I - "$ROOT/root.json" "$ROOT/kit.json" Package.resolved Packages/DictateKit/Package.resolved <<'PY'
import json, sys

root, kit = (json.load(open(path)) for path in sys.argv[1:3])

def target(manifest):
    t = next(t for t in manifest["targets"] if t["name"] == "DictateKit")
    return {key: t.get(key) for key in ("dependencies", "resources", "settings", "type")}

def package(manifest):
    return {
        "toolsVersion": manifest["toolsVersion"],
        "platforms": manifest["platforms"],
        "defaultLocalization": manifest["defaultLocalization"],
        "products": manifest["products"],
        "dependencies": manifest["dependencies"],
    }

def pins(path):
    return {pin["identity"]: pin["state"] for pin in json.load(open(path))["pins"]}

problems = []
if target(root) != target(kit):
    problems.append(f"the DictateKit target differs:\n  root: {target(root)}\n  kit:  {target(kit)}")
for key, value in package(root).items():
    if value != package(kit)[key]:
        problems.append(f"{key} differs:\n  root: {value}\n  kit:  {package(kit)[key]}")
root_pins, kit_pins = pins(sys.argv[3]), pins(sys.argv[4])
for identity, state in kit_pins.items():
    if root_pins.get(identity) != state:
        problems.append(f"the {identity} pin differs:\n  root: {root_pins.get(identity)}\n  kit:  {state}")

if problems:
    print("Package.swift and Packages/DictateKit/Package.swift drifted apart:", *problems, sep="\n")
    sys.exit(1)
print("Both DictateKit manifests and their pins match.")
PY
