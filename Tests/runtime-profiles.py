"""Stage installed vendor binaries in a temporary directory; never edit the apps.
Usage: python3 Tests/runtime-profiles.py build/wine-runtime-cli
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

cli = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="mhud-vendor-profiles-") as scratch:
    for app in ("CrossOver.app", "CrossOver Preview.app"):
        root = Path("/Applications") / app / "Contents/SharedSupport/CrossOver/lib/wine"
        for source in sorted(root.glob("*/winemac.so")):
            staged = Path(scratch) / (app + source.parent.name + ".dylib")
            subprocess.run([cli, "stage", str(source), str(staged)], check=True, capture_output=True)
            original, patched = source.read_bytes(), staged.read_bytes()
            count, size = struct.unpack_from("<II", original, 16)
            assert struct.unpack_from("<II", patched, 16) == (count + 1, size + 48)
            assert original[:16] == patched[:16]
            assert original[24:32 + size] == patched[24:32 + size]
            assert original[32 + size + 48:] == patched[32 + size + 48:]
            assert struct.unpack_from("<III", patched, 32 + size) == (0x80000018, 48, 24)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                            "--preserve-metadata=identifier", str(staged)], check=True, capture_output=True)
            subprocess.run(["codesign", "--verify", "--strict", str(staged)], check=True)
            print(f"PASS {app} {source.parent.name}: existing commands and section bytes preserved; staged signature verified")
