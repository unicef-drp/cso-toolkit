"""The Python auditor's ``io-open-write`` rule fires on raw ``open()``.

Lines are matched after string literals are scrubbed, so the rule used to
look for a quoted mode that was never there and never fired.
"""

from __future__ import annotations

import pytest

import cso_toolkit as m


def _rules(tmp_path, line: str) -> list:
    d = tmp_path / "scripts"
    d.mkdir(exist_ok=True)
    (d / "s.py").write_text(line + "\n", encoding="utf-8")
    out = m.test_scripts(str(d), verbose=False)
    return out["rule"].tolist()


@pytest.mark.parametrize("line", [
    'fh = open(p, "w")',
    "fh = open(p, 'a')",
    'fh = open(p, mode="wb")',
    'with open(f"{out}/x.txt", "w") as fh:',
    'fh = open(p, "r")',
])
def test_open_with_a_mode_is_flagged(tmp_path, line):
    assert "io-open-write" in _rules(tmp_path, line)


@pytest.mark.parametrize("line", [
    "fh = open(p)",
    'x = reopen(p, "w")',
    '# open(p, "w") in a comment',
    'fh = open(p, "w")  # cso-allow: io-open-write',
])
def test_not_flagged(tmp_path, line):
    assert "io-open-write" not in _rules(tmp_path, line)
