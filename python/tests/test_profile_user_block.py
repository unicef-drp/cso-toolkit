"""create_profile(): the generated profile reads the user's block of
~/.config/user_config.yml (DW-Production's template nests each person's
settings under their user name), falls back to top-level keys, resolves
dw_mode as dw_mode_by_project[repo] then dw_mode, and stops with the YAML to
add when neither is set. review_profile() warns on a profile that reads
top-level keys only. Mirror of
r/tests/testthat/test-create-profile-user-block.R.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

import cso_toolkit as m

pytest.importorskip("yaml")


def _run(tmp_path: Path, config, username: str = "tester", repo: str = "proj-x"):
    """Run a freshly generated profile in a child Python, as ``username``."""
    work = tmp_path / "work"
    (work / ".git").mkdir(parents=True)
    profile = Path(m.create_profile(repo, output_path=work))
    home = tmp_path / "home"
    (home / ".config").mkdir(parents=True)
    if config is not None:
        (home / ".config" / "user_config.yml").write_text(config, encoding="utf-8")
    env = dict(os.environ, USERNAME=username, USER=username, USERPROFILE=str(home))
    code = (f"exec(compile(open({str(profile)!r}, encoding='utf-8').read(), 'profile', 'exec'));"
            "print(f'MODE={dw_mode}')")
    res = subprocess.run([sys.executable, "-c", code], cwd=work, env=env,
                         capture_output=True, text=True)
    return res.returncode, res.stdout + res.stderr


def test_user_block(tmp_path):
    rc, out = _run(tmp_path, 'tester:\n  dw_mode: "reviewer"\nsomeone_else:\n  dw_mode: "producer"\n')
    assert rc == 0, out
    assert "MODE=reviewer" in out


def test_project_override(tmp_path):
    rc, out = _run(tmp_path, 'tester:\n  dw_mode: "reviewer"\n  dw_mode_by_project:\n'
                             '    proj-x: "producer"\n    other-repo: "reviewer"\n')
    assert rc == 0, out
    assert "MODE=producer" in out


def test_top_level_fallback(tmp_path):
    rc, out = _run(tmp_path, 'dw_mode: "producer"\n')
    assert rc == 0, out
    assert "MODE=producer" in out


def test_missing_mode_shows_the_yaml(tmp_path):
    rc, out = _run(tmp_path, 'someone_else:\n  dw_mode: "producer"\n')
    assert rc != 0
    assert "No valid dw_mode" in out
    assert 'tester:\n        dw_mode: "reviewer"' in out
    assert 'dw_mode_by_project:\n          proj-x: "producer"' in out
    # The profile stopped before the print ran. Look for a printed line, not
    # the text anywhere: since Python 3.13 the traceback quotes the -c source,
    # which contains "MODE=".
    assert not any(line.startswith("MODE=") for line in out.splitlines())


def test_review_profile_user_block(tmp_path):
    p = m.create_profile("proj-x", output_path=tmp_path)
    rev = m.review_profile(p, verbose=False)
    assert rev.loc[rev["check"] == "User block in user_config.yml", "status"].item() == "pass"
    old = tmp_path / "profile_old.py"
    old.write_text(
        "import os, random, yaml\nrandom.seed(1)\nUSERNAME = os.environ.get('USERNAME')\n"
        "user_config = yaml.safe_load(open('user_config.yml'))\n"
        "dw_mode = user_config.get('dw_mode')\nassert dw_mode in ('producer', 'reviewer')\n"
        "def dw_require_no_api(): pass\nprofile_old = True\n", encoding="utf-8")
    rev = m.review_profile(old, verbose=False)
    row = rev[rev["check"] == "User block in user_config.yml"].iloc[0]
    assert row["status"] == "warn" and "top-level keys only" in row["detail"]


def test_agent_session_as_producer_gets_a_notice(tmp_path, monkeypatch):
    """#173: the profile prints a notice in a Claude Code producer session only."""
    monkeypatch.setenv("CLAUDE_CODE_CHILD_SESSION", "1")
    rc, out = _run(tmp_path / "a", 'tester:\n  dw_mode: "producer"\n')
    assert rc == 0, out
    assert "a Claude Code session is running as producer" in out
    monkeypatch.delenv("CLAUDE_CODE_CHILD_SESSION")
    rc, out = _run(tmp_path / "b", 'tester:\n  dw_mode: "producer"\n')
    assert rc == 0 and "Claude Code session" not in out
    monkeypatch.setenv("CLAUDE_CODE_CHILD_SESSION", "1")
    rc, out = _run(tmp_path / "c", 'tester:\n  dw_mode: "reviewer"\n')
    assert rc == 0 and "Claude Code session" not in out
