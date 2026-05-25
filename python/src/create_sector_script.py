"""Auto-generate a prefilled sector-run script for a data-warehouse pipeline.

Python port of ``r/R/create_sector_script.R``.  Unlike the R version
(which writes a ``00_run_<sector>.R`` file), this helper writes a
``00_run_<sector>.py`` template suitable for Python-side pipelines.

Public entry points:

* :func:`create_sector_script` — generic; configurable layout.
* :func:`create_dw_sector_script` — DW-Production convention wrapper.
"""

from __future__ import annotations

import datetime as _dt
import getpass
import os
from pathlib import Path
from typing import List, Optional, Sequence, Union


def create_sector_script(
    sector_name: str,
    sector_code: str,
    base_dir: Union[str, Path] = ".",
    *,
    profile_name: str = "profile_DW_Production",
    profile_file: str = "profile_DW-Production.py",
    input_subpath: Sequence[str] = ("01_dw_prep", "011_input"),
    output_subpath: Sequence[str] = ("01_dw_prep", "013_output"),
    overwrite: bool = False,
) -> str:
    """Generate a prefilled sector-run script for a DW pipeline.

    Creates ``<base_dir>/<sector_code>/00_run_<sector_code>.py`` populated
    with a template that includes profile verification, time-stamped
    logging, runtime tracking, try-except error handling, and placeholder
    input/output paths.

    Parameters
    ----------
    sector_name
        Full name of the sector (e.g. ``"Nutrition"``, ``"WASH"``).
    sector_code
        Short abbreviation used in the folder structure and filenames
        (e.g. ``"nt"``, ``"ws"``).
    base_dir
        Parent directory under which
        ``<sector_code>/00_run_<sector_code>.py`` will be created.
    profile_name
        Name of the project profile sentinel the generated script will
        check for.
    profile_file
        Filename of the profile script.
    input_subpath, output_subpath
        Path components, relative to ``projectFolder``, that the
        generated script uses for the sector's input / output folders.
    overwrite
        If ``False``, raise when the target file already exists.

    Returns
    -------
    str
        The absolute path of the file written.
    """
    user = os.environ.get("USERNAME") or getpass.getuser()
    timestamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")

    script_dir = Path(base_dir) / sector_code
    script_path = script_dir / f"00_run_{sector_code}.py"
    try:
        script_dir.mkdir(parents=True, exist_ok=True)
    except PermissionError as exc:
        raise PermissionError(
            f"[cso_toolkit.create_sector_script] Cannot create "
            f"{script_dir}.\n"
            f"  Underlying error: {exc.strerror or exc}\n"
            "  Fix: check filesystem permissions, or pass a writable "
            "base_dir."
        ) from exc
    if script_path.exists() and not overwrite:
        raise FileExistsError(
            f"[cso_toolkit.create_sector_script] File already exists: "
            f"{script_path}\n"
            "  Fix: pass overwrite=True to replace it, or delete the "
            "existing script first."
        )

    input_components = ", ".join(repr(c) for c in (*input_subpath, sector_code))
    output_components = ", ".join(repr(c) for c in (*output_subpath, sector_code))

    template = f'''"""
{sector_name} Run Script.

File     : {script_path.as_posix()}
Purpose  : Executes {sector_name} data preparation steps.
Author   : {user}
Created  : {timestamp}

This script is called by the project's top-level runner.
Required modules must be loaded by {profile_file}.
"""

from __future__ import annotations

import datetime as _dt
import importlib.util
import sys
from pathlib import Path

# =======================
# 0. Profile Verification
# =======================
# Load via importlib.util because the profile filename may contain a hyphen
# (e.g. profile_DW-Production.py), which is not a legal Python module name
# and so would not work with a plain `from <stem> import ...`.
_profile_path = Path(__file__).resolve().parent
_profile_candidates = list(_profile_path.parents) + [Path.cwd()]
_profile_file_path = None
for _root in _profile_candidates:
    _cand = _root / "{profile_file}"
    if _cand.is_file():
        _profile_file_path = _cand
        break
if _profile_file_path is None:
    raise RuntimeError(
        "[X] Could not locate {profile_file} on any ancestor path. "
        "Place the profile next to this script or in a parent folder."
    )
_spec = importlib.util.spec_from_file_location("_cso_profile_module", _profile_file_path)
_profile_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_profile_module)
{profile_name} = getattr(_profile_module, "{profile_name}", False)
log_message = getattr(_profile_module, "log_message", None)
projectFolder = getattr(_profile_module, "projectFolder", None)

if not {profile_name}:
    raise RuntimeError(
        "[X] Project profile not initialised. Verify {profile_file} sets "
        "{profile_name} = True."
    )
if log_message is None or projectFolder is None:
    raise RuntimeError(
        "[X] Project profile missing required exports (log_message, "
        "projectFolder). Re-generate the profile via create_profile()."
    )

# Sector-error flag consumed by the top-level runner.
errorOccurred = False


# =======================
# 1. Start Logging for {sector_name}
# =======================
log_message("[*] Starting {sector_name} module")
start_time = _dt.datetime.now()


# =======================
# 2. Sector Execution Block
# =======================
try:
    # -------------------------------------------------------------
    # 2.1 Define input and output paths
    # -------------------------------------------------------------
    input_folder = Path(projectFolder, {input_components})
    output_folder = Path(projectFolder, {output_components})
    output_folder.mkdir(parents=True, exist_ok=True)

    # -------------------------------------------------------------
    # 2.2 Load and process data (customize below)
    # -------------------------------------------------------------
    # Example:
    # import pandas as pd
    # raw_data = pd.read_csv(input_folder / "input_file.csv")
    # processed_data = (
    #     raw_data
    #     .dropna(subset=["indicator"])
    #     .groupby("country", as_index=False)["value"]
    #     .mean()
    # )

    # -------------------------------------------------------------
    # 2.3 Export outputs
    # -------------------------------------------------------------
    # processed_data.to_csv(output_folder / "cleaned_data.csv", index=False)

    # -------------------------------------------------------------
    # 2.4 Wrap up
    # -------------------------------------------------------------
    duration = (_dt.datetime.now() - start_time).total_seconds()
    log_message(
        f"[OK] {sector_name} module completed | Duration: {{duration:.1f}} seconds"
    )

except Exception as exc:  # noqa: BLE001
    errorOccurred = True
    log_message(f"[X] Error in {sector_name} module: {{exc}}")
'''

    script_path.write_text(template, encoding="utf-8")
    print(f"[OK] Sector script created: {script_path}")
    return str(script_path.resolve())


def create_dw_sector_script(
    sector_name: str,
    sector_code: str,
    project_root: Union[str, Path] = ".",
    overwrite: bool = False,
) -> str:
    """Generate a prefilled sector-run script using DW-Production conventions.

    Thin convenience wrapper around :func:`create_sector_script` that
    fills in the DW-Production layout: scripts land at
    ``01_dw_prep/012_codes/<sector_code>/00_run_<sector_code>.py``, input
    under ``01_dw_prep/011_input/<sector_code>``, output under
    ``01_dw_prep/013_output/<sector_code>``.

    Parameters
    ----------
    sector_name, sector_code, overwrite
        Forwarded to :func:`create_sector_script`.
    project_root
        Project root that ``base_dir`` is resolved against.

    Returns
    -------
    str
    """
    return create_sector_script(
        sector_name=sector_name,
        sector_code=sector_code,
        base_dir=Path(project_root) / "01_dw_prep" / "012_codes",
        profile_name="profile_DW_Production",
        profile_file="profile_DW-Production.py",
        input_subpath=("01_dw_prep", "011_input"),
        output_subpath=("01_dw_prep", "013_output"),
        overwrite=overwrite,
    )
