# Builds the release zip for GitHub and Nexus Mods.
#
#   python tools/build_release.py              # runs the tests first
#   python tools/build_release.py --skip-tests
#
# Output: dist/OfflineProgress-v<version>.zip, laid out so it can be extracted straight into the
# Palworld (or PalServer) folder, plus a .sha256 file next to it.
import argparse
import hashlib
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MOD = os.path.join(ROOT, "OfflineProgress")
DIST = os.path.join(ROOT, "dist")
ZIP_PREFIX = "Pal/Binaries/Win64/ue4ss/Mods/OfflineProgress/"

# Files shipped from the repository root into the mod folder.
DOCS = ["README.md", "LICENSE", "CHANGELOG.md"]
# Never shipped: per-install runtime data.
EXCLUDE = {"state.lua", "state.lua.bak", "state.lua.tmp"}


def fail(msg):
    print(f"BUILD FAILED: {msg}")
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def version():
    m = re.search(r'local MOD_VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"', read(os.path.join(MOD, "Scripts", "main.lua")))
    if not m:
        fail("MOD_VERSION not found in Scripts/main.lua")
    return m.group(1)


def check_release_settings():
    cfg = read(os.path.join(MOD, "Scripts", "config.lua"))
    checks = [
        (r"^\s*dryRun = false,", "config.lua: dryRun must be false for a release"),
        (r"debugTiming = \{ enabled = false", "config.lua: debugTiming must be off for a release"),
        (r"clearSafeMode = false,", "config.lua: clearSafeMode must be false for a release"),
    ]
    for pattern, msg in checks:
        if not re.search(pattern, cfg, re.M):
            fail(msg)


def check_lua_syntax(files):
    try:
        from lupa import lua54
    except ImportError:
        print("  (lupa not installed; skipping Lua syntax check)")
        return
    lua = lua54.LuaRuntime()
    load = lua.eval("function(src, name) local f, err = load(src, '=' .. name); return err end")
    for path in files:
        if path.endswith(".lua"):
            err = load(read(path), os.path.basename(path))
            if err:
                fail(f"Lua syntax error: {err}")


def collect():
    files = []
    for dirpath, _, names in os.walk(MOD):
        for name in sorted(names):
            if name in EXCLUDE:
                continue
            full = os.path.join(dirpath, name)
            files.append((full, ZIP_PREFIX + os.path.relpath(full, MOD).replace(os.sep, "/")))
    for doc in DOCS:
        full = os.path.join(ROOT, doc)
        if not os.path.exists(full):
            fail(f"missing {doc}")
        files.append((full, ZIP_PREFIX + doc))
    required = [ZIP_PREFIX + "enabled.txt", ZIP_PREFIX + "Scripts/main.lua", ZIP_PREFIX + "Scripts/config.lua",
                ZIP_PREFIX + "Scripts/adapter.lua"]
    names = {arc for _, arc in files}
    for r in required:
        if r not in names:
            fail(f"missing {r}")
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()

    ver = version()
    print(f"Building OfflineProgress v{ver}")

    if not args.skip_tests:
        print("Running tests...")
        result = subprocess.run([sys.executable, os.path.join(ROOT, "tests", "run_tests.py")],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout[-3000:])
            fail("tests failed")
        print("  all tests passed")

    check_release_settings()
    files = collect()
    check_lua_syntax([f for f, _ in files])

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"OfflineProgress-v{ver}.zip")
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for full, arc in files:
            z.write(full, arc)

    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            fail(f"corrupt entry in zip: {bad}")
        listing = z.namelist()

    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    with open(out + ".sha256", "w", encoding="utf-8") as f:
        f.write(f"{digest}  {os.path.basename(out)}\n")

    print(f"\n{os.path.relpath(out, ROOT)}  ({os.path.getsize(out):,} bytes)")
    for name in listing:
        print("  " + name)
    print(f"SHA-256: {digest}")


if __name__ == "__main__":
    main()
