# Runs the Lua test suite without a standalone Lua install.
#   pip install lupa
#   python tests/run_tests.py
import glob
import os
import sys

from lupa import lua54

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TESTS = os.path.join(ROOT, "tests")

# Tests run from inside the mod folder, the same way UE4SS loads Scripts/*.lua.
os.chdir(os.path.join(ROOT, "OfflineProgress"))
failed = 0
for path in sorted(glob.glob(os.path.join(TESTS, "test_*.lua"))):
    print(f"== tests/{os.path.basename(path)}", flush=True)
    lua = lua54.LuaRuntime()
    lua.globals().print = lambda *a: print("\t".join(str(x) for x in a), flush=True)
    lua.execute('package.path = "../tests/?.lua;" .. package.path')
    with open(path, encoding="utf-8") as f:
        failed += lua.execute(f.read()) or 0
print("\nALL TESTS PASSED" if failed == 0 else f"\n{failed} TEST(S) FAILED", flush=True)
sys.exit(1 if failed else 0)
