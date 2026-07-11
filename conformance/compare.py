#!/usr/bin/env python3
# =====================================================================
# Cross-language conformance comparator
# ---------------------------------------------------------------------
# Asserts that the per-language driver outputs agree value-for-value.
# Compares numerically (OBS_VALUE within 1e-9) so formatting differences
# like R's `1e+05` vs `100000` don't count as a mismatch. Missing is `""`
# in all languages.
#
# Usage:
#   python conformance/compare.py r=out_r.csv python=out_python.csv \
#                                 stata=out_stata.csv
# The FIRST file is the reference; every other is compared to it.
# Missing files are skipped with a warning (so the Stata gate can be
# absent until a STATA_LIC runner is provisioned). Exit 1 on any diff.
# =====================================================================
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

KEYS = ["REF_AREA", "INDICATOR", "SEX", "AGE", "TIME_PERIOD"]
TOL = 1e-9


def load(path: str) -> dict[tuple, float | None]:
    rows: dict[tuple, float | None] = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        missing = [c for c in KEYS + ["OBS_VALUE"] if c not in reader.fieldnames]
        if missing:
            raise SystemExit(f"[compare] {path}: missing columns {missing} "
                             f"(has {reader.fieldnames})")
        for r in reader:
            key = tuple((r[k] or "").strip() for k in KEYS)
            v = (r.get("OBS_VALUE") or "").strip()
            rows[key] = None if v == "" else float(v)
    return rows


def diff(ref_name, ref, name, other) -> list[str]:
    out: list[str] = []
    kr, ko = set(ref), set(other)
    for k in sorted(kr - ko):
        out.append(f"  key {k} present in {ref_name} but missing in {name}")
    for k in sorted(ko - kr):
        out.append(f"  key {k} present in {name} but missing in {ref_name}")
    for k in sorted(kr & ko):
        a, b = ref[k], other[k]
        if a is None and b is None:
            continue
        if (a is None) != (b is None):
            out.append(f"  key {k}: {ref_name}={a!r} vs {name}={b!r} (missing mismatch)")
        elif not math.isclose(a, b, abs_tol=TOL):
            out.append(f"  key {k}: {ref_name}={a} vs {name}={b} (delta={abs(a - b):.3g})")
    return out


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: compare.py label=path [label=path ...]")
    specs = []
    for arg in sys.argv[1:]:
        label, _, path = arg.partition("=")
        if not path:
            raise SystemExit(f"[compare] bad arg {arg!r}; expected label=path")
        specs.append((label, path))

    present = [(lbl, p) for lbl, p in specs if Path(p).exists()]
    for lbl, p in specs:
        if not Path(p).exists():
            print(f"[compare] SKIP {lbl}: {p} not found "
                  f"(driver did not run — e.g. Stata not provisioned)")
    if len(present) < 2:
        print(f"[compare] only {len(present)} driver output(s) present; "
              f"need >= 2 to compare. Nothing to verify.")
        return 0 if present else 1

    ref_name, ref_path = present[0]
    ref = load(ref_path)
    print(f"[compare] reference: {ref_name} ({len(ref)} rows)")
    failed = False
    for name, path in present[1:]:
        other = load(path)
        d = diff(ref_name, ref, name, other)
        if d:
            failed = True
            print(f"[compare] MISMATCH {ref_name} vs {name}:")
            print("\n".join(d))
        else:
            print(f"[compare] OK {ref_name} == {name} ({len(other)} rows)")
    if failed:
        print("[compare] FAIL: cross-language outputs diverge.")
        return 1
    print("[compare] PASS: all driver outputs agree within tolerance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
