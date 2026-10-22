"""Verify patch bytes and loading with hardened owned hosts, no Wine/game changes.
Usage: python3 Tests/weak-dependency.py PATCH_CLI REAL_HELPER
"""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parent
cli, helper = map(lambda p: str(Path(p).resolve()), sys.argv[1:])
env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "STEAM_DYLD_", "WINE", "CX_"))}
env["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
def run(args, **kwargs):
    return subprocess.run(args, env=env, text=True, capture_output=True, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="mhud weak checks ") as scratch:
    root = Path(scratch)
    for arch in ("arm64", "x86_64"):
        original, patched, host = [root / (arch + suffix) for suffix in ("-original.dylib", "-patched.dylib", "-host")]
        run(["xcrun", "clang", "-arch", arch, "-dynamiclib", "-Wl,-headerpad,0x100", str(source / "weak-fixture.c"), "-o", str(original)])
        run([cli, "stage", str(original), str(patched)])
        before, after = original.read_bytes(), patched.read_bytes()
        count, size = struct.unpack_from("<II", before, 16)
        assert struct.unpack_from("<II", after, 16) == (count + 1, size + 48)
        assert before[:16] == after[:16] and before[24:32 + size] == after[24:32 + size]
        assert before[32 + size + 48:] == after[32 + size + 48:], "section bytes moved or changed"
        assert struct.unpack_from("<III", after, 32 + size) == (0x80000018, 48, 24)
        assert b"@loader_path/MHUD.dylib\0" in after[32 + size:32 + size + 48]
        run(["codesign", "--force", "--sign", "-", str(patched)])
        run(["xcrun", "clang", "-arch", arch, str(source / "wine-launch-probe.c"), "-o", str(host)])
        run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(source / "weak-host.entitlements"), str(host)])
        link = root / "MHUD.dylib"
        link.symlink_to(helper)
        env["PROBE_DLOPEN"] = str(patched)
        result = run([str(host)])
        assert "loaded=1\n" in result.stdout, result
        link.unlink()
        result = run([str(host)])
        assert "loaded=0\n" in result.stdout, result
        print(f"PASS {arch}: patch preserves section bytes; hardened host loads helper without DYLD; missing helper is harmless")
