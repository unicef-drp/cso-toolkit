"""cso_toolkit_diff / cso_toolkit_pull / cso_toolkit_sync: the update path
for vendored helpers.  Mirror of r/tests/testthat/test-cso_toolkit_pull.R.

Offline: a throwaway upstream repository with tags v0.1.0, v0.2.0, v0.10.0
(and a pre-release) stands in for cso-toolkit, read through
``toolkit_source``; a consumer folder holds 00_functions/ at v0.1.0.  One
test reads the real repository on GitHub; one checks that R and Python
write the same bytes.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import importlib
import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

import cso_toolkit as m
from cso_toolkit import _state
# The package exports the function cso_toolkit_sync(), which shadows the
# submodule of the same name as an attribute: take the module itself.
sync = importlib.import_module("cso_toolkit.cso_toolkit_sync")

REPO = Path(__file__).resolve().parents[2]

NEWS_010 = "# NEWS\n\n## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n"
NEWS_020 = ("# NEWS\n\n## v0.2.0 (2026-02-01)\n\n### Added\n\n- a.R learns a trick\n\n"
            "### Changed\n\n- a.R now returns a list\n\n"
            "## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n")
NEWS_0100 = ("# NEWS\n\n## Unreleased\n\n- nothing yet\n\n"
             "## v0.10.0 (2026-03-01)\n\n### Breaking\n\n- b.R drops an argument\n\n"
             "### Fixed\n\n- a.R off-by-one\n\n"
             "## v0.2.0 (2026-02-01)\n\n### Added\n\n- a.R learns a trick\n\n"
             "### Changed\n\n- a.R now returns a list\n\n"
             "## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n")

MANIFEST = (
    "# Vendoring manifest -- a comment that must survive\n"
    'source: "unicef-drp/cso-toolkit"\n'
    'pulled_version: "v0.1.0"   # the pin\n'
    "%DATE%\n"
    'pulled_by: "someone"\n'
    '# target_version: "v0.2.0"\n'
    "custom_key: keep me\n"
    "\n"
    "vendored:\n"
    "  - a.R\n  - b.R\n  - c.R\n  - e.R\n  - gone.R\n  - m.R\n  - p.py\n"
    "\n"
    "local_edits:\n  - e.R\n"
)


def git(d: Path, *args: str) -> str:
    res = subprocess.run(["git", "-C", str(d), "-c", "user.name=test",
                          "-c", "user.email=test@example.org", "-c", "core.autocrlf=false",
                          *args], capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    return res.stdout.strip()


def put(d: Path, rel: str, text: str) -> None:
    p = d / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(text.encode("utf-8"))


def make_upstream(root: Path) -> Path:
    if shutil.which("git") is None:
        pytest.skip("git not installed")
    d = root / "upstream"
    d.mkdir(parents=True)
    put(d, "r/DESCRIPTION", "Package: csotoolkit\nVersion: 0.0.1\n")
    for f in ("a", "b", "c", "e", "m", "gone"):
        put(d, f"r/R/{f}.R", f"# {f} at v0.1.0\n")
    put(d, "python/src/p.py", "# p at v0.1.0\n")
    put(d, "NEWS.md", NEWS_010)
    git(d, "init", "--quiet")
    git(d, "add", "-A")
    git(d, "commit", "--quiet", "-m", "v0.1.0")
    git(d, "tag", "v0.1.0")
    for f in ("a", "b", "e", "m"):
        put(d, f"r/R/{f}.R", f"# {f} at v0.2.0\n")
    put(d, "python/src/p.py", "# p at v0.2.0\n")
    (d / "r/R/gone.R").unlink()
    put(d, "NEWS.md", NEWS_020)
    git(d, "add", "-A")
    git(d, "commit", "--quiet", "-m", "v0.2.0")
    git(d, "tag", "v0.2.0")
    put(d, "r/R/a.R", "# a at v0.10.0\n")
    put(d, "NEWS.md", NEWS_0100)
    git(d, "add", "-A")
    git(d, "commit", "--quiet", "-m", "v0.10.0")
    git(d, "tag", "-a", "v0.10.0", "-m", "v0.10.0")
    put(d, "r/R/a.R", "# a at v0.11.0-rc1\n")
    git(d, "commit", "--quiet", "-a", "-m", "rc")
    git(d, "tag", "v0.11.0-rc1")
    put(d, "r/R/a.R", "# a in the working tree, never read\n")
    return d


def make_consumer(root: Path, up: Path, date: str = 'pulled_date: "2026-01-02"',
                  extra: str = "", name: str = "consumer") -> Path:
    d = root / name
    fd = d / "00_functions"
    fd.mkdir(parents=True)
    sha = git(up, "rev-list", "-n", "1", "v0.1.0")
    for f in ("a.R", "b.R", "c.R", "e.R", "gone.R"):
        (fd / f).write_bytes(sync._cso_git_blob(up, sha, f"r/R/{f}"))
    (fd / "p.py").write_bytes(sync._cso_git_blob(up, sha, "python/src/p.py"))
    put(fd, "b.R", "# b at v0.1.0, edited here\n")
    put(fd, ".toolkit_manifest.yml", MANIFEST.replace("%DATE%", date) + extra)
    git(d, "init", "--quiet")
    git(d, "add", "-A")
    git(d, "commit", "--quiet", "-m", "vendor-v0.1.0")
    return fd


def tag_blob(up: Path, tag: str, path: str) -> bytes:
    return sync._cso_git_blob(up, git(up, "rev-list", "-n", "1", tag), path)


def mf(fd: Path) -> list:
    return (fd / ".toolkit_manifest.yml").read_text(encoding="utf-8").splitlines()


@pytest.fixture
def env(tmp_path, monkeypatch):
    """upstream + consumer; producer mode; dwFunct -> the consumer's 00_functions."""
    monkeypatch.delenv("CSO_TOOLKIT_ROOT", raising=False)
    up = make_upstream(tmp_path)

    def consumer(apis: bool = True, **kw) -> Path:
        fd = make_consumer(tmp_path, up, **kw)
        monkeypatch.setattr(_state, "dwFunct", str(fd), raising=False)
        monkeypatch.setattr(_state, "dw_apis_allowed", apis, raising=False)
        return fd
    return up, consumer


def by_file(df, col="status") -> dict:
    return dict(zip(df["file"], df[col]))


def test_diff_reports_every_status(env, capsys):
    up, consumer = env
    fd = consumer()
    d = m.cso_toolkit_diff("v0.2.0", toolkit_source=up, verbose=False)
    st = by_file(d)
    assert st == {"a.R": "changed", "b.R": "local_edit", "c.R": "unchanged",
                  "e.R": "local_edit", "gone.R": "missing_upstream",
                  "m.R": "missing_local", "p.py": "changed"}
    assert d.attrs["target_version"] == "v0.2.0"
    assert d.attrs["target_commit"] == git(up, "rev-list", "-n", "1", "v0.2.0")
    assert d.loc[d.file == "m.R", "sha256_local"].isna().all()
    assert d.loc[d.file != "gone.R", "sha256_target"].str.fullmatch(r"[0-9a-f]{64}").all()
    # CRLF-only differences are not changes.
    (fd / "c.R").write_bytes(b"# c at v0.1.0\r\n")
    assert by_file(m.cso_toolkit_diff("0.2.0", toolkit_source=up, verbose=False))["c.R"] == "unchanged"
    m.cso_toolkit_diff("v0.2.0", toolkit_source=up)
    assert "2 changed" in capsys.readouterr().out


def test_diff_latest_tag_is_numeric(env):
    up, consumer = env
    consumer()
    d = m.cso_toolkit_diff(toolkit_source=up, verbose=False)
    assert d.attrs["target_version"] == "v0.10.0"
    assert sync._cso_latest_version_tag(["v1.2.0", "v1.10.0", "v2.0.0-rc1", "x"]) == "v1.10.0"
    assert sync._cso_latest_version_tag(["v2.0.0-rc1", "latest"]) is None


def test_diff_reviewer_mode(env, monkeypatch):
    up, consumer = env
    consumer(apis=False)
    with pytest.raises(PermissionError, match=r"\[cso_toolkit\.cso_toolkit_diff\].*reviewer mode(?s:.*)Fix:"):
        m.cso_toolkit_diff("v0.2.0", verbose=False)
    assert len(m.cso_toolkit_diff("v0.2.0", toolkit_source=up, verbose=False)) == 7
    monkeypatch.setenv("CSO_TOOLKIT_ROOT", str(up))
    assert len(m.cso_toolkit_diff("v0.2.0", verbose=False)) == 7


def test_unknown_extension(env):
    up, consumer = env
    fd = consumer()
    p = fd / ".toolkit_manifest.yml"
    p.write_text(p.read_text(encoding="utf-8").replace("  - p.py\n", "  - p.py\n  - notes.txt\n"),
                 encoding="utf-8")
    with pytest.raises(ValueError, match=r"\[cso_toolkit\.cso_toolkit_diff\].*notes\.txt"):
        m.cso_toolkit_diff("v0.2.0", toolkit_source=up, verbose=False)


def test_dry_run_writes_nothing(env):
    up, consumer = env
    fd = consumer()
    before = {p.name: p.read_bytes() for p in fd.iterdir()}
    with pytest.warns(UserWarning, match="gone.R"):
        res = m.cso_toolkit_pull("v0.2.0", dry_run=True, toolkit_source=up, verbose=False)
    assert {p.name: p.read_bytes() for p in fd.iterdir()} == before
    act = by_file(res, "action")
    assert (act["a.R"], act["m.R"], act["b.R"], act["gone.R"]) == \
        ("would_update", "would_add", "skipped_local_edit", "kept")


def test_pull_writes_tag_bytes_and_repins(env):
    up, consumer = env
    fd = consumer()
    old = mf(fd)
    with pytest.warns(UserWarning, match="Not in cso-toolkit v0.2.0, kept as vendored: gone.R"):
        res = m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, verbose=False)
    for f in ("a.R", "m.R"):
        assert (fd / f).read_bytes() == tag_blob(up, "v0.2.0", f"r/R/{f}")
    assert (fd / "p.py").read_bytes() == tag_blob(up, "v0.2.0", "python/src/p.py")
    assert (fd / "b.R").read_bytes() == b"# b at v0.1.0, edited here\n"
    assert (fd / "e.R").read_bytes() == b"# e at v0.1.0\n"
    assert (fd / "gone.R").exists()
    act = by_file(res, "action")
    assert [act[f] for f in ("a.R", "m.R", "p.py", "b.R", "e.R", "c.R", "gone.R")] == \
        ["updated", "added", "updated", "skipped_local_edit", "skipped_local_edit", "none", "kept"]
    assert not list(fd.glob("*.cso_tmp"))
    new = mf(fd)
    sha = git(up, "rev-list", "-n", "1", "v0.2.0")
    assert new[2] == 'pulled_version: "v0.2.0"   # the pin'
    assert new[3] == f'pulled_commit: "{sha}"'
    assert new[4] == f'pulled_date: "{dt.date.today().isoformat()}"'
    assert new[5] == f'pulled_by: "{sync._cso_user()}"'
    assert new[:2] + new[6:] == old[:2] + old[5:]
    man = yaml.safe_load((fd / ".toolkit_manifest.yml").read_text(encoding="utf-8"))
    assert man["custom_key"] == "keep me" and man["local_edits"] == ["e.R"]
    assert "target_version" not in man


def test_pull_keeps_pulled_at_and_files_block(env):
    up, consumer = env
    h010 = hashlib.sha256(b"# a at v0.1.0\n").hexdigest()
    fd = consumer(date='pulled_at: "2026-01-02"\npulled_commit: "' + "0" * 40 + '"',
                  extra=f'\nfiles:\n  a.R    : "{h010}"\n  c.R    : "{h010}"\n')
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, verbose=False)
    new = mf(fd)
    assert new[3] == f'pulled_at: "{dt.date.today().isoformat()}"'
    assert new[4] == f'pulled_commit: "{git(up, "rev-list", "-n", "1", "v0.2.0")}"'
    assert not any(ln.startswith("pulled_date:") for ln in new)
    assert f'  a.R    : "{hashlib.sha256((fd / "a.R").read_bytes()).hexdigest()}"' in new
    assert f'  c.R    : "{hashlib.sha256((fd / "c.R").read_bytes()).hexdigest()}"' in new


def test_dirty_folder_refused(env):
    up, consumer = env
    fd = consumer()
    put(fd, "c.R", "# c, uncommitted edit\n")
    with pytest.raises(RuntimeError, match=r"\[cso_toolkit\.cso_toolkit_pull\].*uncommitted changes"):
        m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, verbose=False)
    assert (fd / "a.R").read_bytes() == b"# a at v0.1.0\n"


def test_downgrade(env):
    up, consumer = env
    fd = consumer()
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.10.0", confirm=False, toolkit_source=up, verbose=False)
    git(fd.parent, "add", "-A")
    git(fd.parent, "commit", "--quiet", "-m", "v0.10.0")
    with pytest.raises(ValueError, match=r"allow_downgrade=True"):
        m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, verbose=False)
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, allow_downgrade=True,
                           verbose=False)
    assert (fd / "a.R").read_bytes() == b"# a at v0.2.0\n"
    assert 'pulled_version: "v0.2.0"   # the pin' in mf(fd)


def test_same_tag_and_moved_tag(env, capsys):
    up, consumer = env
    fd = consumer(date='pulled_date: "2026-01-02"\npulled_commit: "' + "1" * 40 + '"')
    old = mf(fd)
    with pytest.warns(UserWarning, match="now points to"):
        res = m.cso_toolkit_pull("v0.1.0", confirm=False, toolkit_source=up)
    assert "already at v0.1.0" in capsys.readouterr().out
    assert set(res["action"]) <= {"none", "skipped_local_edit", "kept"}
    assert mf(fd) == old


def test_missing_tag(env):
    up, consumer = env
    consumer()
    with pytest.raises(LookupError, match=r"(?s)Tag v9\.9\.9 does not exist.*fetch --tags"):
        m.cso_toolkit_pull("v9.9.9", confirm=False, toolkit_source=up, verbose=False)


def test_reviewer_refuses_pull_and_sync(env):
    up, consumer = env
    consumer(apis=False)
    with pytest.raises(PermissionError, match=r"\[cso_toolkit\.cso_toolkit_pull\].*reviewer mode"):
        m.cso_toolkit_pull("v0.2.0", toolkit_source=up)
    with pytest.raises(PermissionError, match=r"\[cso_toolkit\.cso_toolkit_sync\].*reviewer mode"):
        m.cso_toolkit_sync(toolkit_source=up)


def test_noninteractive_confirm_refused(env, monkeypatch):
    up, consumer = env
    fd = consumer()
    monkeypatch.setattr(sync, "_cso_interactive", lambda: False)
    with pytest.raises(RuntimeError, match=r"(?s)\[cso_toolkit\.cso_toolkit_pull\].*Fix:.*confirm=False"):
        m.cso_toolkit_pull("v0.2.0", toolkit_source=up, verbose=False)
    assert (fd / "a.R").read_bytes() == b"# a at v0.1.0\n"
    assert 'pulled_version: "v0.1.0"   # the pin' in mf(fd)


def test_confirm_prompts(env, monkeypatch, capsys):
    up, consumer = env
    fd = consumer()
    answers = ["d", "o", "s", "o"]          # a.R: diff then overwrite; m.R: skip; p.py: overwrite
    asked = []
    monkeypatch.setattr(sync, "_cso_interactive", lambda: True)
    monkeypatch.setattr(sync, "_cso_ask", lambda p: (asked.append(p), answers.pop(0))[1])
    with pytest.warns(UserWarning):
        res = m.cso_toolkit_pull("v0.2.0", toolkit_source=up)
    out = capsys.readouterr().out
    assert len(asked) == 4
    assert "a.R changed upstream (v0.1.0 -> v0.2.0)" in asked[0]
    assert "+# a at v0.2.0" in out
    act = by_file(res, "action")
    assert [act[f] for f in ("a.R", "m.R", "p.py")] == ["updated", "skipped", "updated"]
    assert not (fd / "m.R").exists()
    assert "next: read NEWS, run tools/check.R and the tests, commit 00_functions/ in one commit" in out


def test_sync_up_to_date(env, capsys):
    up, consumer = env
    fd = consumer()
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.10.0", confirm=False, toolkit_source=up, verbose=False)
    old = mf(fd)
    assert m.cso_toolkit_sync(toolkit_source=up) is None
    assert "up to date: vendored v0.10.0, latest release v0.10.0" in capsys.readouterr().out
    assert mf(fd) == old


def test_sync_prints_news_between(env, capsys):
    up, consumer = env
    consumer()
    with pytest.warns(UserWarning):
        res = m.cso_toolkit_sync(dry_run=True, toolkit_source=up)
    out = capsys.readouterr().out
    assert "release notes v0.1.0 -> v0.10.0" in out
    news = res.attrs["news"]
    assert any("## v0.10.0" in ln for ln in news) and any("## v0.2.0" in ln for ln in news)
    assert not any("## v0.1.0" in ln or "Unreleased" in ln for ln in news)
    for ln in ("!! ### Breaking", "!! - b.R drops an argument", "!! ### Changed", "   ### Fixed"):
        assert ln in news
    assert "flagged:\n   v0.10.0: ### Breaking\n   v0.2.0: ### Changed" in out
    assert not any(ln != ln.rstrip() for ln in news)   # blank lines carry no padding
    assert by_file(res, "action")["a.R"] == "would_update"
    assert res.attrs["target_version"] == "v0.10.0"
    nw = sync._cso_news_between(NEWS_0100, "v0.2.0", "v0.10.0")["lines"]
    assert not any("## v0.2.0" in ln for ln in nw)


def test_github_path_over_a_url(env, monkeypatch):
    up, consumer = env
    fd = consumer()
    url = "file:///" + up.resolve().as_posix().lstrip("/")
    monkeypatch.setattr(sync, "_cso_remote_url", lambda s: url)
    assert sync._cso_ls_remote_latest("unicef-drp/cso-toolkit") == "v0.10.0"
    d = m.cso_toolkit_diff("v0.2.0", verbose=False)
    assert list(d["status"]) == list(m.cso_toolkit_diff("v0.2.0", toolkit_source=up, verbose=False)["status"])
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.2.0", confirm=False, verbose=False)
    assert (fd / "a.R").read_bytes() == tag_blob(up, "v0.2.0", "r/R/a.R")
    with pytest.raises(ConnectionError, match=r"\[cso_toolkit\.cso_toolkit_diff\] Could not read tag v9\.9\.9"):
        m.cso_toolkit_diff("v9.9.9", verbose=False)


@pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")
def test_real_repository_v091_dry_run(tmp_path, monkeypatch):
    """Network: the GitHub clone path against the real repository."""
    if os.environ.get("CSO_OFFLINE") or sync._cso_ls_remote_latest("unicef-drp/cso-toolkit") is None:
        pytest.skip("GitHub not reachable")
    monkeypatch.delenv("CSO_TOOLKIT_ROOT", raising=False)
    (tmp_path / ".toolkit_manifest.yml").write_text(
        'source: "unicef-drp/cso-toolkit"\npulled_version: "v0.9.0"\n'
        "vendored:\n  - cso_toolkit_sync.R\n  - dw_io.R\nlocal_edits: []\n", encoding="utf-8")
    monkeypatch.setattr(_state, "dwFunct", str(tmp_path), raising=False)
    monkeypatch.setattr(_state, "dw_apis_allowed", True, raising=False)
    res = m.cso_toolkit_pull("v0.9.1", dry_run=True, verbose=False)
    assert list(res["status"]) == ["missing_local", "missing_local"]
    assert list(res["action"]) == ["would_add", "would_add"]
    assert len(res.attrs["target_commit"]) == 40
    assert res["sha256_target"].str.fullmatch(r"[0-9a-f]{64}").all()
    assert not (tmp_path / "dw_io.R").exists()


def _rscript():
    cand = os.environ.get("RSCRIPT") or shutil.which("Rscript")
    if not cand:
        for p in sorted(Path("C:/Program Files/R").glob("R-*/bin/Rscript.exe")):
            cand = str(p)
    return cand


@pytest.mark.skipif(not _rscript(), reason="R not available")
def test_r_python_parity(tmp_path, monkeypatch):
    """R and Python pull the same consumer to the same bytes, manifest included."""
    monkeypatch.delenv("CSO_TOOLKIT_ROOT", raising=False)
    up = make_upstream(tmp_path)
    extra = '\nfiles:\n  a.R    : "' + "0" * 64 + '"\n'
    py = make_consumer(tmp_path, up, extra=extra, name="py")
    r = make_consumer(tmp_path, up, extra=extra, name="r")
    monkeypatch.setattr(_state, "dwFunct", str(py), raising=False)
    monkeypatch.setattr(_state, "dw_apis_allowed", True, raising=False)
    with pytest.warns(UserWarning):
        m.cso_toolkit_pull("v0.2.0", confirm=False, toolkit_source=up, verbose=False)
    code = (
        f"suppressMessages(pkgload::load_all({(REPO / 'r').as_posix()!r}, quiet = TRUE));"
        f"assign('dwFunct', {r.as_posix()!r}, envir = .GlobalEnv);"
        "assign('dw_apis_allowed', TRUE, envir = .GlobalEnv);"
        f"invisible(suppressWarnings(cso_toolkit_pull('v0.2.0', confirm = FALSE,"
        f" toolkit_source = {up.as_posix()!r}, verbose = FALSE)))"
    )
    res = subprocess.run([_rscript(), "--no-init-file", "-e", code], capture_output=True, text=True)
    if res.returncode != 0 and "there is no package called" in res.stderr:
        pytest.skip("pkgload not installed")
    assert res.returncode == 0, res.stderr
    names = sorted(p.name for p in py.iterdir())
    assert names == sorted(p.name for p in r.iterdir())
    for n in names:
        assert (py / n).read_bytes() == (r / n).read_bytes(), n
