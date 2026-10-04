#!/usr/bin/env python3
"""Check the packaged device application before publishing an IPA."""

import plistlib
import sys
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError(f"Corrupt ZIP entry: {bad_member}")
        names = set(archive.namelist())
        app = "Payload/Animeko.app/"
        info = plistlib.loads(archive.read(app + "Info.plist"))
        if info.get("CFBundlePackageType") != "APPL":
            raise ValueError("The IPA must contain an application bundle")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("The IPA must target a physical iOS device")
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if not info.get(key):
                raise ValueError(f"Missing {key}")
        executable = app + info["CFBundleExecutable"]
        if executable not in names or archive.getinfo(executable).file_size == 0:
            raise ValueError("Missing application executable")
        for framework in ("application", "MediampFFmpegKit"):
            prefix = app + f"Frameworks/{framework}.framework/"
            if prefix + framework not in names:
                raise ValueError(f"Missing embedded {framework} framework")
        print(f"Validated {info['CFBundleIdentifier']} "
              f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


if __name__ == "__main__":
    verify(sys.argv[1])
