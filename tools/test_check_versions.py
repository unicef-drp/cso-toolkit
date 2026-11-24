"""Tests for tools/check_versions.py: the stamps in this tree agree, and drift is caught.

    python -m pytest tools
"""
from __future__ import annotations

import importlib.util
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
spec = importlib.util.spec_from_file_location("check_versions", HERE / "check_versions.py")
cv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cv)

FILES = sorted({f for f, _ in cv.STAMPS + cv.DATES} | {"r/DESCRIPTION", "NEWS.md", "README.md"})


def copy_repo(tmp: Path) -> Path:
    for rel in FILES:
        (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / rel, tmp / rel)
    return tmp


def edit(root: Path, rel: str, old: str, new: str, count: int = 1) -> None:
    p = root / rel
    text = p.read_text(encoding="utf-8")
    assert old in text, f"{old!r} not in {rel}"
    p.write_text(text.replace(old, new, count), encoding="utf-8")


def test_the_stamps_in_this_tree_agree():
    assert cv.check(REPO) == []


def test_a_stale_stamp_is_named_with_its_line(tmp_path):
    root = copy_repo(tmp_path)
    v, _ = cv.release(root)
    edit(root, "python/src/__init__.py", f'__version__ = "{v}"', '__version__ = "0.0.1"')
    errs = cv.check(root)
    assert len(errs) == 1 and errs[0].startswith("python/src/__init__.py:")
    assert "0.0.1, expected " + v in errs[0]


def test_a_removed_stamp_is_reported(tmp_path):
    root = copy_repo(tmp_path)
    edit(root, "r/tests/testthat/test-dw_publish.R", "body$toolkit", "body$tk")
    assert any(e.startswith("r/tests/testthat/test-dw_publish.R: no stamp") for e in cv.check(root))


def test_dates_follow_news_and_the_readme_row_must_exist(tmp_path):
    root = copy_repo(tmp_path)
    v, date = cv.release(root)
    edit(root, ".zenodo.json", f'"publication_date": "{date}"', '"publication_date": "1999-01-01"')
    edit(root, "README.md", f"| `v{v}` | {date} |", f"| `v{v}` | 1999-01-01 |")
    errs = cv.check(root)
    assert any(e.startswith(".zenodo.json:") and "1999-01-01" in e for e in errs)
    assert any(e.startswith("README.md: no version-table row") for e in errs)


def test_a_bumped_description_without_news_fails(tmp_path):
    root = copy_repo(tmp_path)
    v, _ = cv.release(root)
    edit(root, "r/DESCRIPTION", f"Version: {v}", "Version: 9.9.9")
    errs = cv.check(root)
    assert errs[0].startswith("NEWS.md: no '## v9.9.9")
    assert any("expected 9.9.9" in e for e in errs)
