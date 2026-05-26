"""Verify every public-facing error path returns an informative message.

Each test triggers a known failure and asserts the raised exception:

1. is the right type (not a generic Exception / RuntimeError unless
   that's the documented contract),
2. starts with the ``[cso_toolkit.<func>]`` prefix so library messages
   can be grepped, and
3. contains a ``Fix:`` line giving the caller a clear remediation.

Run with::

    python python/tests/manual/error_envelope_test.py
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Type


def _bootstrap_package() -> None:
    repo_root = Path(__file__).resolve().parents[3]
    src = repo_root / "python" / "src"
    tmp = Path(tempfile.mkdtemp(prefix="cso_toolkit_err_"))
    shutil.copytree(src, tmp / "cso_toolkit")
    sys.path.insert(0, str(tmp))


_bootstrap_package()

import cso_toolkit
from cso_toolkit import _state as state
import pandas as pd

_PREFIX_RE = re.compile(r"^\[cso_toolkit\.[A-Za-z_][A-Za-z0-9_.]*(/[A-Za-z_]+)?\]")
_passed = 0
_failed: list[str] = []


def expect(name: str, exc_type: Type[BaseException], call) -> None:
    """Run ``call()``, assert the right exception with the standard envelope."""
    global _passed
    try:
        call()
    except exc_type as exc:
        # KeyError repr-wraps its single string arg in quotes via str().
        # Pull the underlying message via .args[0] when possible.
        msg = exc.args[0] if exc.args and isinstance(exc.args[0], str) else str(exc)
        if not _PREFIX_RE.match(msg):
            _failed.append(f"{name}: message lacks [cso_toolkit.<func>] prefix: {msg!r}")
            return
        if "Fix:" not in msg and "Fix " not in msg:
            _failed.append(f"{name}: message lacks 'Fix:' guidance: {msg!r}")
            return
        _passed += 1
        print(f"  [OK] {name}")
    except BaseException as exc:
        _failed.append(
            f"{name}: expected {exc_type.__name__}, got "
            f"{type(exc).__name__}: {exc}"
        )
    else:
        _failed.append(f"{name}: no exception raised")


print("error envelope checks")
print("-" * 72)

# --- _state.configure rejects unknown keys ---
expect(
    "_state.configure unknown key",
    AttributeError,
    lambda: state.configure(unknown_global=1),
)

# --- dw_resolve_path: bad kind ---
expect(
    "dw_resolve_path bad kind",
    ValueError,
    lambda: cso_toolkit.dw_resolve_path(name="x.csv", sector="t", kind="bogus"),
)

# --- dw_resolve_path: unset root ---
import importlib

# Clear all state for the "unset root" check
state.teamsWrkData = None
expect(
    "dw_resolve_path unset teamsWrkData",
    ValueError,
    lambda: cso_toolkit.dw_resolve_path(name="x.csv", sector="t", kind="wrk"),
)

# --- dw_resolve_path: neither path nor name ---
state.configure(teamsWrkData="/tmp/wrk")
expect(
    "dw_resolve_path no path or name",
    ValueError,
    lambda: cso_toolkit.dw_resolve_path(kind="wrk"),
)

# --- dw_isid: missing key column ---
df = pd.DataFrame({"a": [1, 2, 3]})
expect(
    "dw_isid missing key column",
    ValueError,
    lambda: cso_toolkit.dw_isid(df, keys=["missing"], where="test"),
)

# --- dw_isid: duplicates ---
df_dup = pd.DataFrame({"a": [1, 1, 2]})
expect(
    "dw_isid duplicate rows",
    ValueError,
    lambda: cso_toolkit.dw_isid(df_dup, keys=["a"], where="test"),
)

# --- dw_verify_z: bad compare ---
expect(
    "dw_verify_z bad compare",
    ValueError,
    lambda: cso_toolkit.dw_verify_z("/tmp/anything", compare="md5"),
)

# --- dw_save: reviewer canonical guard ---
state.configure(
    teamsWrkData=tempfile.mkdtemp(),
    teamsWrkDataCanonical="/data/wrk-canonical",
    dw_mode="reviewer",
)
expect(
    "dw_save reviewer canonical guard",
    PermissionError,
    lambda: cso_toolkit.dw_save(
        pd.DataFrame({"a": [1]}),
        path="/data/wrk-canonical/t/x.csv",
    ),
)

# --- dw_save: overwrite=False on existing file ---
# v0.4.0 producer pre-flight requires at least one mirror — configure
# a sibling canonical root under the tempdir so the pre-flight passes
# and the test reaches the overwrite-gate assertion it targets.
with tempfile.TemporaryDirectory() as tdir:
    state.configure(
        dw_mode="producer",
        teamsWrkData=tdir,
        teamsWrkDataCanonical=str(Path(tdir) / ".canon"),
        teamsFolderCanonical=str(Path(tdir) / ".canon"),
        dw_z_available=False,
    )
    p = Path(tdir) / "existing.csv"
    p.write_text("a\n1\n", encoding="utf-8")
    expect(
        "dw_save overwrite=False",
        FileExistsError,
        lambda: cso_toolkit.dw_save(
            pd.DataFrame({"a": [1]}),
            path=str(p),
            overwrite=False,
        ),
    )

# --- dw_save: unsupported extension ---
with tempfile.TemporaryDirectory() as tdir:
    state.configure(
        dw_mode="producer",
        teamsWrkData=tdir,
        teamsWrkDataCanonical=str(Path(tdir) / ".canon"),
        teamsFolderCanonical=str(Path(tdir) / ".canon"),
        dw_z_available=False,
    )
    expect(
        "dw_save unsupported extension",
        ValueError,
        lambda: cso_toolkit.dw_save(
            pd.DataFrame({"a": [1]}),
            path=f"{tdir}/x.xyz",
        ),
    )

# --- dw_use: missing file, no fallback ---
expect(
    "dw_use file not found no fallback",
    FileNotFoundError,
    lambda: cso_toolkit.dw_use("/nonexistent/path/x.csv", fallback_canonical=False),
)

# --- dw_use: unsupported extension ---
with tempfile.TemporaryDirectory() as tdir:
    p = Path(tdir) / "x.xyz"
    p.write_text("garbage", encoding="utf-8")
    expect(
        "dw_use unsupported extension",
        ValueError,
        lambda: cso_toolkit.dw_use(str(p), fallback_canonical=False),
    )

# --- dw_compare: no common by columns ---
expect(
    "dw_compare no common by",
    ValueError,
    lambda: cso_toolkit.dw_compare(
        pd.DataFrame({"a": [1]}),
        pd.DataFrame({"b": [2]}),
        by=["a"],
    ),
)

# --- dw_merge: bad how ---
expect(
    "dw_merge bad how",
    ValueError,
    lambda: cso_toolkit.dw_merge(
        pd.DataFrame({"a": [1]}),
        pd.DataFrame({"a": [1]}),
        by=["a"],
        how="bogus",
    ),
)

# --- dw_api_fetch: bad api ---
state.configure(dw_apis_allowed=True, teamsRawData="/tmp/raw",
                 teamsRawDataCanonical="/tmp/raw-canonical")
expect(
    "dw_api_fetch unsupported api",
    ValueError,
    lambda: cso_toolkit.dw_api_fetch(api="bogus_api", cache_key="x"),
)

# --- dw_api_fetch: reviewer mode lockout ---
state.configure(dw_apis_allowed=False)
expect(
    "dw_api_fetch reviewer lockout",
    PermissionError,
    lambda: cso_toolkit.dw_api_fetch(api="uis", cache_key="never_cached_anything"),
)

# --- dw_api_cached: missing cache ---
expect(
    "dw_api_cached missing cache",
    FileNotFoundError,
    lambda: cso_toolkit.dw_api_cached(api="uis", cache_key="never_cached_anything"),
)

# --- aggregate_data: bad method ---
df_agg = pd.DataFrame({"by": ["A"], "val": [1.0], "wt": [1.0]})
expect(
    "aggregate_data bad method",
    ValueError,
    lambda: cso_toolkit.aggregate_data(
        df_agg, value="val", weight="wt", by=["by"], method="bogus",
    ),
)

# --- aggregate_data: missing column ---
expect(
    "aggregate_data missing column",
    KeyError,
    lambda: cso_toolkit.aggregate_data(
        df_agg, value="missing_col", weight="wt", by=["by"],
    ),
)

# --- aggregate_data_v2: bad threshold ---
expect(
    "aggregate_data_v2 bad threshold",
    ValueError,
    lambda: cso_toolkit.aggregate_data_v2(
        df_agg, value="val", weight="wt", by=["by"], coverage_threshold=2.5,
    ),
)

# --- dw_nestweight: missing column ---
expect(
    "dw_nestweight missing value column",
    KeyError,
    lambda: cso_toolkit.dw_nestweight(
        pd.DataFrame({"a": [1]}), value="missing", by="a", verbose=False,
    ),
)

# --- dw_nestweight: data not DataFrame ---
expect(
    "dw_nestweight bad data type",
    TypeError,
    lambda: cso_toolkit.dw_nestweight(
        {"a": [1]}, value="a", by="a", verbose=False,
    ),
)

# --- generate_markdown_report: missing input file ---
expect(
    "generate_markdown_report missing file",
    FileNotFoundError,
    lambda: cso_toolkit.generate_markdown_report(
        "/nonexistent/foo.csv",
        country_column="c", year_column="y",
        indicator_column="i", value_column="v",
    ),
)

# --- create_sector_script: overwrite=False existing ---
with tempfile.TemporaryDirectory() as tdir:
    cso_toolkit.create_sector_script("WASH", "ws", base_dir=tdir)
    expect(
        "create_sector_script overwrite=False existing",
        FileExistsError,
        lambda: cso_toolkit.create_sector_script(
            "WASH", "ws", base_dir=tdir, overwrite=False,
        ),
    )

# --- create_profile: overwrite=False existing ---
with tempfile.TemporaryDirectory() as tdir:
    cso_toolkit.create_profile("X", output_path=tdir)
    expect(
        "create_profile overwrite=False existing",
        FileExistsError,
        lambda: cso_toolkit.create_profile("X", output_path=tdir, overwrite=False),
    )

# --- review_profile: missing file ---
expect(
    "review_profile missing file",
    FileNotFoundError,
    lambda: cso_toolkit.review_profile("/nonexistent/profile.py", verbose=False),
)

# --- test_scripts: missing path ---
expect(
    "test_scripts missing path",
    FileNotFoundError,
    lambda: cso_toolkit.test_scripts("/nonexistent/dir", verbose=False),
)

# --- test_scripts: error_on_violation triggers ---
with tempfile.TemporaryDirectory() as tdir:
    bad = Path(tdir) / "bad.py"
    bad.write_text("import pandas as pd\ndf = pd.read_csv('x.csv')\n", encoding="utf-8")
    expect(
        "test_scripts error_on_violation",
        RuntimeError,
        lambda: cso_toolkit.test_scripts(
            bad, error_on_violation=True, verbose=False,
        ),
    )

# --- cso_toolkit_pull: reviewer mode ---
state.configure(dw_apis_allowed=False)
expect(
    "cso_toolkit_pull reviewer mode",
    PermissionError,
    lambda: cso_toolkit.cso_toolkit_pull(target_version="v0.2.0"),
)

# --- cso_toolkit_pull: no manifest ---
state.configure(dw_apis_allowed=True, dwFunct="/nonexistent/missing")
expect(
    "cso_toolkit_pull missing manifest",
    FileNotFoundError,
    lambda: cso_toolkit.cso_toolkit_pull(target_version="v0.2.0"),
)

print("-" * 72)
print(f"{_passed} passed, {len(_failed)} failed")
if _failed:
    for f in _failed:
        print(f"  [X] {f}")
    sys.exit(1)
print("\nAll error envelopes pass the WHAT / WHY / HOW contract.")
