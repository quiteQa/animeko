"""Fast SDK checks for native media sources; the IPA job performs the full link."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
packages = pathlib.Path(sys.argv[1])
framework_dirs = set()
for bundle in packages.rglob("*.xcframework"):
    if "-GPL" in str(bundle):
        continue
    with (bundle / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    for library in info["AvailableLibraries"]:
        if library["SupportedPlatform"] == "ios" and not library.get("SupportedPlatformVariant"):
            framework = bundle / library["LibraryIdentifier"] / library["LibraryPath"]
            framework_dirs.add(str(framework.parent))
            break
if not framework_dirs:
    raise RuntimeError("Pinned MPVKit frameworks were not resolved")
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
frameworks = [argument for path in sorted(framework_dirs) for argument in ["-F", path]]
app = root / "app/ios-native/App"
sources = sorted((app / "Sources/Media").glob("*.swift"))
sources += sorted((app / "Sources/Features/Player/Support").glob("*.swift"))
sources.append(app / "Sources/Common/Diagnostics.swift")
sources += [app / "Sources/Features/Player/MPVBackend.swift", app / "Sources/Features/Player/MPVPlayer.swift"]
subprocess.run(["xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-sdk", sdk,
                "-target", "arm64-apple-ios26.0", "-import-objc-header",
                str(app / "Sources/Media/AnimekoNative-Bridging-Header.h"),
                *frameworks, *map(str, sources)], check=True)
subprocess.run(["xcrun", "clang", "-fsyntax-only", "-fobjc-arc", "-fmodules", "-isysroot", sdk,
                "-target", "arm64-apple-ios26.0", *frameworks,
                str(app / "Sources/Media/ANMediaBridge.m")], check=True)
