"""create_profile(include_z_drive_check=True) must emit a timeout-bounded Z:
probe, not a bare Path.is_dir() that can hang for the full SMB timeout on a
dead-mapped Windows drive letter (#106 item 3).  Mirror of
r/tests/testthat/test-create-profile-z-probe.R.
"""

from __future__ import annotations

import ast
import os
import time
from pathlib import Path

import pytest

import cso_toolkit as m


def _generate(tmp_path: Path, include_z: bool) -> Path:
    return Path(m.create_profile("zprobe", output_path=tmp_path,
                                 include_z_drive_check=include_z))


def _extract_probe(path: Path):
    """Compile only the generated _dw_drive_available definition."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    fn = next(n for n in tree.body
              if isinstance(n, ast.FunctionDef) and n.name == "_dw_drive_available")
    ns: dict = {"os": os, "Path": Path}
    exec("import subprocess", ns)
    exec(compile(ast.Module(body=[fn], type_ignores=[]), str(path), "exec"), ns)
    return ns["_dw_drive_available"]


def test_z1_block_uses_timeout_probe(tmp_path):
    text = _generate(tmp_path, True).read_text(encoding="utf-8")
    assert "def _dw_drive_available(root, timeout=3):" in text
    assert "dw_z_available = _dw_drive_available(network_root)" in text
    assert "Path(network_root).is_dir()" not in text
    ast.parse(text)  # the generated profile is valid Python


def test_z2_no_block_without_flag(tmp_path):
    text = _generate(tmp_path, False).read_text(encoding="utf-8")
    assert "_dw_drive_available" not in text
    assert "network_root" not in text


def test_z3_probe_existing_and_missing(tmp_path):
    probe = _extract_probe(_generate(tmp_path, True))
    assert probe(str(tmp_path)) is True
    assert probe(str(tmp_path / "no-such-folder-zprobe")) is False


@pytest.mark.skipif(os.name != "nt", reason="drive letters are Windows-only")
def test_z4_drive_letter_answers_within_timeout(tmp_path):
    probe = _extract_probe(_generate(tmp_path, True))
    start = time.monotonic()
    res = probe("Q:/", timeout=3)
    assert res in (True, False)
    assert time.monotonic() - start < 10
