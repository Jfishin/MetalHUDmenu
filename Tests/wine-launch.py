"""Owned launch checks; no Steam, CrossOver, bottle, or game changes.
Usage: python3 Tests/wine-launch.py build/wine-foundation
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parent
resources = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="mhud wine checks ") as scratch:
    root = Path(scratch)
    for name in ("mhud-run", "libMHUDStats.dylib"):
        shutil.copy2(resources / name, root / name)
    helper = str(root / "libMHUDStats.dylib")
    wrapper = str(root / "mhud-run")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "STEAM_DYLD_", "MHUD_", "WINE", "CX_"))}
    env["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
    for arch in ("arm64", "x86_64"):
        probe = root / ("probe-" + arch)
        subprocess.run(["xcrun", "clang", "-arch", arch, str(source / "wine-launch-probe.c"), "-o", str(probe)], env=env, check=True)
        for name, backup, nested in (("no overlay", None, False), ("existing overlay", "/usr/lib/libz.1.dylib", False),
                                      ("already present", helper, False), ("nested wrappers", "/usr/lib/libz.1.dylib", True)):
            case_env = dict(env, PROBE_EXIT="17")
            if backup is not None:
                case_env["STEAM_DYLD_INSERT_LIBRARIES"] = backup
            cmd = [wrapper] + ([wrapper] if nested else []) + ["/bin/sh", str(source / "notproton-launcher.sh"), str(probe), "argument with spaces", "literal;$()"]
            result = subprocess.run(cmd, env=case_env, text=True, capture_output=True)
            assert result.returncode == 17, (name, result.stderr)
            values = result.stdout.splitlines()
            expected = helper if backup in (None, helper) else backup + ":" + helper
            assert "loaded=1" in values, (arch, name, values, result.stderr)
            assert "DYLD_INSERT_LIBRARIES=" + expected in values, values
            assert "STEAM_DYLD_INSERT_LIBRARIES=" + expected in values, values
            assert values[-2:] == ["arg=argument with spaces", "arg=literal;$()"], values
            print(f"PASS {arch}: {name}; helper loaded, arguments and exit preserved")
