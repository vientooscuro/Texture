#!/usr/bin/env python3
"""Reject Texture binaries that call a missing text-layout implementation."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
with (root / "Info.plist").open("rb") as source:
    libraries = plistlib.load(source)["AvailableLibraries"]
selector = "-[ASTextLayout textBoundingSizeUsingTruncatedLineConstrainedToWidth:]"
for library in libraries:
    binary = root / library["LibraryIdentifier"] / library["LibraryPath"] / "AsyncDisplayKit"
    for arch in library["SupportedArchitectures"]:
        symbols = subprocess.check_output(["xcrun", "nm", "-arch", arch, str(binary)], text=True)
        if selector not in symbols:
            sys.exit(f"Missing {selector} in {library['LibraryIdentifier']} ({arch})")
        print(f"PASS {library['LibraryIdentifier']} ({arch})")
