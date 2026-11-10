#!/usr/bin/env bash
# 在 iOS 模拟器中运行 build-ios.sh 产出的冒烟测试. 用法: ./run-smoke.sh [build-ios.sh 的输出目录]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
binary="$out/ios-simulator/bin/lt-smoke"
codesign -s - -f "$binary"

device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, items in sorted(devices.items(), reverse=True):
    if "iOS" in runtime:
        for d in items:
            if d["name"].startswith("iPhone"):
                print(d["udid"]); sys.exit(0)
sys.exit("no iPhone simulator")')
echo "Simulator $device"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b
# 模拟器进程直接访问 Mac 的文件系统
mkdir -p "$out/smoke-data"
xcrun simctl spawn "$device" "$binary" "$out/smoke-data"
