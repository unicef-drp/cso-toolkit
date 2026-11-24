"""A sector script scaffolded by create_sector_script() runs against a profile
scaffolded by create_profile() (#236): the profile sets rootFolder (the
working directory unless set first) and projectFolder. Mirror of
r/tests/testthat/test-profile-sector-script.R.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

import cso_toolkit as m

pytest.importorskip("yaml")


def test_sector_script_runs_against_create_profile(tmp_path):
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    profile = Path(m.create_profile("proj-x", output_path=repo))
    script = Path(m.create_sector_script(
        "Water", "ws", base_dir=repo,
        profile_name="profile_proj_x", profile_file=profile.name))
    home = tmp_path / "home"
    (home / ".config").mkdir(parents=True)
    (home / ".config" / "user_config.yml").write_text('tester:\n  dw_mode: "reviewer"\n',
                                                      encoding="utf-8")
    env = dict(os.environ, USERNAME="tester", USER="tester", USERPROFILE=str(home))
    res = subprocess.run([sys.executable, str(script)], cwd=repo, env=env,
                         capture_output=True, text=True)
    out = res.stdout + res.stderr
    assert res.returncode == 0, out
    assert (repo / "01_dw_prep" / "013_output" / "ws").is_dir(), out


def test_profile_defines_project_folder(tmp_path):
    profile = Path(m.create_profile("proj-x", output_path=tmp_path))
    text = profile.read_text(encoding="utf-8")
    assert 'rootFolder = os.path.abspath(globals().get("rootFolder") or os.getcwd())' in text
    assert "projectFolder = rootFolder" in text
