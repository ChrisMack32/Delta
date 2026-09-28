#!/bin/bash
# Build Delta and install it on the iPhone Duo simulator in Xcode 27.1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

XCODE_APP="/Applications/Xcode.app"
DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
export DEVELOPER_DIR

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "Install Xcode 27.1 at $XCODE_APP. Device Hub 27.1 includes the iPhone Duo simulator."
  exit 1
fi

XCODE_VERSION="$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | awk 'NR==1 { print $2 }')"
if [[ "$XCODE_VERSION" != "27.1" ]]; then
  echo "This script uses Xcode 27.1 at $XCODE_APP. That app reports $XCODE_VERSION."
  echo "Device Hub 27.1 is the install that includes the iPhone Duo simulator."
  exit 1
fi

echo "Fetching emulator cores..."
git config --local url."https://github.com/".insteadOf "git@github.com:"
git submodule sync --recursive
git submodule update --init --recursive || true
git submodule foreach --recursive 'git checkout -f HEAD >/dev/null'
git submodule update --init --recursive

echo "Applying Xcode 27.1 build fixes..."
python3 - "$ROOT" << 'PY'
import os, re, sys
root = sys.argv[1]
target_re = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);")

def replacement(match):
    parts = [int(p) for p in match.group(1).split(".")]
    major = parts[0]
    if major < 15:
        return "IPHONEOS_DEPLOYMENT_TARGET = 15.0;"
    if major >= 27:
        return "IPHONEOS_DEPLOYMENT_TARGET = 17.0;"
    return match.group(0)

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", "DerivedData", "build")]
    for name in filenames:
        if not name.endswith(".pbxproj"):
            continue
        path = os.path.join(dirpath, name)
        text = open(path, encoding="utf-8", errors="replace").read()
        updated = target_re.sub(replacement, text)
        if updated != text:
            open(path, "w", encoding="utf-8").write(updated)
            print("updated", os.path.relpath(path, root))

header = os.path.join(root, "Cores/SNESDeltaCore/snes9x/conffile.h")
source = os.path.join(root, "Cores/SNESDeltaCore/snes9x/conffile.cpp")
if os.path.exists(header):
    text = open(header, encoding="utf-8").read()
    text2 = text.replace(
        "bool operator()(const ConfigEntry &a, const ConfigEntry &b);",
        "bool operator()(const ConfigEntry &a, const ConfigEntry &b) const;",
        1,
    ).replace(
        "bool operator()(const ConfigEntry &a, const ConfigEntry &b){",
        "bool operator()(const ConfigEntry &a, const ConfigEntry &b) const {",
        1,
    )
    if text2 != text:
        open(header, "w", encoding="utf-8").write(text2)
        print("updated Cores/SNESDeltaCore/snes9x/conffile.h")
if os.path.exists(source):
    text = open(source, encoding="utf-8").read()
    old = "bool ConfigFile::ConfigEntry::section_then_key_less::operator()(const ConfigEntry &a, const ConfigEntry &b) {"
    new = "bool ConfigFile::ConfigEntry::section_then_key_less::operator()(const ConfigEntry &a, const ConfigEntry &b) const {"
    text2 = text.replace(old, new, 1)
    if text2 != text:
        open(source, "w", encoding="utf-8").write(text2)
        print("updated Cores/SNESDeltaCore/snes9x/conffile.cpp")
PY

UDID="$(python3 - << 'PY'
import re, subprocess
out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available"], text=True)
section = ""
fallback = ""
booted = ""
for line in out.splitlines():
    header = re.match(r"-- (.*) --", line.strip())
    if header:
        section = header.group(1)
        continue
    if not section.startswith("iOS 27.1"):
        continue
    match = re.search(r"iPhone Duo \(([0-9A-Fa-f-]+)\)", line)
    if not match:
        continue
    if "(Booted)" in line:
        booted = match.group(1)
        break
    if not fallback:
        fallback = match.group(1)
print(booted or fallback)
PY
)"

if [[ -z "$UDID" ]]; then
  echo "No iPhone Duo simulator on iOS 27.1. Install the iOS 27.1 simulator in Xcode 27.1, then run this script again."
  exit 1
fi

echo "Booting iPhone Duo ($UDID)..."
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b

echo "Building Delta for the iPhone Duo simulator..."
xcodebuild \
  -workspace "$ROOT/Delta.xcworkspace" \
  -scheme Delta \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build

APP="$(find "$ROOT/DerivedData/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "Delta.app" -print -quit)"
if [[ -z "$APP" ]]; then
  echo "The build finished without producing Delta.app."
  exit 1
fi

echo "Installing Delta on the iPhone Duo simulator..."
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.rileytestut.Delta

open -a "$XCODE_APP" "$ROOT/Delta.xcworkspace"
echo "Delta is installed on the iPhone Duo simulator. In Xcode, set the run destination to iPhone Duo."
