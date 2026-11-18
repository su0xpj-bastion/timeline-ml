"""Run `tml` once per fault (TML_FAULTS) and require exactly the pinned gates to fail."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def failing(tml: str, fault: str) -> set[str]:
    out = subprocess.run([tml, "run", "--json"], capture_output=True, text=True, env=dict(os.environ, TML_FAULTS=fault)).stdout
    # perf.budgets is timing, not correctness; speech gates skip where recognition is not authorized.
    return {r["name"] for r in json.loads(out) if r["status"] == "fail" and r["name"] != "perf.budgets"}


def main() -> int:
    tml = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build" / "local" / "tml")
    expected = {k: set(v) for k, v in json.loads(subprocess.run([tml, "expected"], capture_output=True, text=True).stdout).items()}
    ok = True
    for fault in [""] + sorted(expected):
        want, got = expected.get(fault, set()), failing(tml, fault)
        ok &= got == want
        print(f"{'ok ' if got == want else 'BAD'} {fault or '(no fault)':32} caught by {sorted(got) or '-'}")
        if got != want:
            print(f"      expected {sorted(want)}")
    print("\nfault matrix: " + ("every fault caught by exactly its pinned gates" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
