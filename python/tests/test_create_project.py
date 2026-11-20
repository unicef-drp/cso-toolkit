"""create_research_project / create_official_stats_project — Python parity
with ``r/tests/testthat/test-create_project.R``: the files written, refusal
to replace existing files, overwrite, workflows, vendoring, cso_project.yml,
the shipped template copies, and byte-for-byte parity with the R sibling
when R is available.
"""

from __future__ import annotations

import datetime as dt
import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

import cso_toolkit as m
from cso_toolkit import create_project as cp

REPO = Path(__file__).resolve().parents[2]
PKG_TEMPLATES = Path(cp.__file__).resolve().parent / "templates"

RESEARCH_FILES = sorted([
    ".githooks/pre-push", ".gitignore", "00_functions/README.md", "CONTRIBUTING.md",
    "R/README.md", "README.md", "cso_project.yml", "data/README.md",
    "data/input_manifest.csv", "data/provenance/README.md", "docs/README.md",
    "output/README.md", "paper/README.md", "references/README.md",
    "tests/testthat.R", "tests/testthat/helper-project.R",
    "tests/testthat/test-project.R", "tools/check.R",
])
OFFICIAL_FILES = sorted([
    ".githooks/pre-push", ".gitignore", "00_documentation/README.md",
    "00_functions/README.md", "01_dw_prep/012_codes/README.md", "CONTRIBUTING.md",
    "README.md", "_config_template/user_config.yml", "cso_project.yml",
    "inputs/README.md", "inputs/input_manifest.csv", "releases/README.md",
    "tests/testthat.R", "tests/testthat/helper-project.R",
    "tests/testthat/test-project.R", "tools/check.R",
])


def on_disk(root: Path) -> list:
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*")
                  if p.is_file() and ".git" not in p.relative_to(root).parts[:1])


def fake_clone(tmp_path: Path, files) -> Path:
    d = tmp_path / "clone"
    (d / "r" / "R").mkdir(parents=True)
    (d / "r" / "DESCRIPTION").write_text("Package: csotoolkit\nVersion: 9.8.7\n", encoding="utf-8")
    for f in files:
        (d / "r" / "R" / f).write_text(f"# stub {f}\n", encoding="utf-8")
    return d


def test_exported():
    assert m.create_research_project is cp.create_research_project
    assert "create_official_stats_project" in m.__all__


def test_research_files(tmp_path):
    root = tmp_path / "proj"
    res = m.create_research_project(root, "single-producer")
    assert list(res["path"]) == RESEARCH_FILES
    assert set(res["status"]) == {"written"}
    assert on_disk(root) == RESEARCH_FILES


def test_official_files(tmp_path):
    root = tmp_path / "proj"
    res = m.create_official_stats_project(root, "single-producer")
    assert list(res["path"]) == OFFICIAL_FILES
    assert on_disk(root) == OFFICIAL_FILES


def test_template_bytes(tmp_path):
    r = tmp_path / "r"
    m.create_research_project(r, "single-producer")
    assert (r / ".gitignore").read_bytes() == \
        (PKG_TEMPLATES / "gitignore" / "research-project.gitignore").read_bytes()
    assert (r / ".githooks" / "pre-push").read_bytes() == \
        (PKG_TEMPLATES / "hooks" / "pre-push").read_bytes()
    o = tmp_path / "o"
    m.create_official_stats_project(o, "single-producer")
    assert (o / ".gitignore").read_bytes() == \
        (PKG_TEMPLATES / "gitignore" / "official-stats.gitignore").read_bytes()


def test_per_kind_settings(tmp_path):
    r, o = tmp_path / "r", tmp_path / "o"
    m.create_research_project(r, "single-producer")
    m.create_official_stats_project(o, "single-producer")
    rchk = (r / "tools" / "check.R").read_text(encoding="utf-8").splitlines()
    ochk = (o / "tools" / "check.R").read_text(encoding="utf-8").splitlines()
    assert '  OUTPUT_DIRS = "",' in rchk
    assert '  OUTPUT_DIRS = "output outputs results wrk",' in ochk
    assert '  AUDIT_PATHS = "01_dw_prep/012_codes",' in ochk
    assert '  CHECKS      = "tracked-data large-files secret-scan sidecars tests",' in rchk
    for root in (r, o):
        for p in root.rglob("*"):
            if p.is_file():
                assert "{{" not in p.read_text(encoding="utf-8"), p


def test_cso_project_yml(tmp_path):
    root = tmp_path / "proj"
    m.create_research_project(root, "multi-producer", members=["jpazvd", "kbarnes"])
    p = yaml.safe_load((root / "cso_project.yml").read_text(encoding="utf-8"))
    assert p["schema"] == "cso_project/1"
    assert p["collaboration"] == "multi-producer"
    assert str(p["collaboration_since"]) == dt.date.today().isoformat()
    assert p["members"] == ["jpazvd", "kbarnes"]
    assert m.dw_collaboration(root=root) == "multi-producer"


def test_collaboration_required(tmp_path):
    root = tmp_path / "proj"
    with pytest.raises(ValueError, match=r"\[cso_toolkit\.create_research_project\].*no default"):
        m.create_research_project(root)
    with pytest.raises(ValueError, match="no default"):
        m.create_official_stats_project(root, "co-producer")
    with pytest.raises(ValueError, match="plain YAML"):
        m.create_research_project(root, "single-producer", members=["a b: c"])
    assert not root.exists()


def test_refuse_then_overwrite(tmp_path):
    root = tmp_path / "proj"
    m.create_research_project(root, "single-producer")
    again = m.create_research_project(root, "single-producer")
    assert set(again["status"]) == {"unchanged"}
    (root / "README.md").write_text("my own readme\n", encoding="utf-8")
    with pytest.raises(FileExistsError, match=r"1 file\(s\) already exist(.|\n)*README.md"):
        m.create_research_project(root, "single-producer")
    assert (root / "README.md").read_text(encoding="utf-8") == "my own readme\n"
    res = m.create_research_project(root, "single-producer", overwrite=True)
    st = dict(zip(res["path"], res["status"]))
    assert st["README.md"] == "overwritten"
    assert {v for k, v in st.items() if k != "README.md"} == {"unchanged"}


def test_conflict_stops_before_any_write(tmp_path):
    root = tmp_path / "proj"
    (root / "tools").mkdir(parents=True)
    (root / "tools" / "check.R").write_text("# my checks\n", encoding="utf-8")
    with pytest.raises(FileExistsError, match="tools/check.R"):
        m.create_official_stats_project(root, "single-producer")
    assert on_disk(root) == ["tools/check.R"]


def test_workflows(tmp_path):
    root = tmp_path / "proj"
    res = m.create_research_project(root, "single-producer", workflows=True)
    wf = ["ci-contract-audit.yml", "ci-hygiene.yml", "ci-manuscript.yml", "ci-r-tests.yml"]
    for w in wf:
        assert f".github/workflows/{w}" in list(res["path"])
        assert (root / ".github" / "workflows" / w).read_bytes() == \
            (PKG_TEMPLATES / "workflows" / w).read_bytes()
        y = yaml.safe_load((root / ".github" / "workflows" / w).read_text(encoding="utf-8"))
        on = y.get("on", y.get(True))
        assert set(on) == {"workflow_dispatch", "pull_request"}
        assert on["pull_request"]["branches"] == ["main"]
    res2 = m.create_official_stats_project(tmp_path / "o", "single-producer", workflows=True)
    assert ".github/workflows/ci-manuscript.yml" not in list(res2["path"])
    assert sum(p.startswith(".github/workflows/") for p in res2["path"]) == 3


def test_vendor(tmp_path):
    files = cp._KINDS["research"]["vendor"]
    clone = fake_clone(tmp_path, files)
    root = tmp_path / "proj"
    res = m.create_research_project(root, "single-producer", vendor=True, toolkit_source=clone)
    for f in files:
        assert f"00_functions/{f}" in list(res["path"])
        assert (root / "00_functions" / f).read_bytes() == (clone / "r" / "R" / f).read_bytes()
    man = yaml.safe_load((root / "00_functions" / ".toolkit_manifest.yml").read_text(encoding="utf-8"))
    assert man["pulled_version"] == "v9.8.7"
    assert man["vendored"] == files
    assert man["local_edits"] == []
    assert cp._CHECKS_LINE in (root / "tools" / "check.R").read_text(encoding="utf-8").splitlines()


def test_vendor_list_adds_required(tmp_path):
    clone = fake_clone(tmp_path, [*cp._VENDOR_REQUIRED, "dw_pop.R"])
    root = tmp_path / "proj"
    m.create_official_stats_project(root, "single-producer", vendor=["dw_pop.R"],
                                    toolkit_source=clone)
    man = yaml.safe_load((root / "00_functions" / ".toolkit_manifest.yml").read_text(encoding="utf-8"))
    assert man["vendored"] == [*cp._VENDOR_REQUIRED, "dw_pop.R"]


def test_vendor_errors(tmp_path, monkeypatch):
    root = tmp_path / "proj"
    with pytest.raises(FileNotFoundError, match="No cso-toolkit clone"):
        m.create_research_project(root, "single-producer", vendor=True,
                                  toolkit_source=tmp_path / "nowhere")
    clone = fake_clone(tmp_path, ["dw_io.R"])
    with pytest.raises(FileNotFoundError, match="cso_toolkit_sync.R"):
        m.create_research_project(root, "single-producer", vendor=True, toolkit_source=clone)
    assert not root.exists()


@pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")
def test_git(tmp_path):
    root = tmp_path / "proj"
    m.create_research_project(root, "single-producer", git=True)

    def g(*a):
        return subprocess.run(["git", "-C", str(root), *a], capture_output=True, text=True)
    assert g("symbolic-ref", "HEAD").stdout.strip() == "refs/heads/develop"
    assert g("config", "core.hooksPath").stdout.strip() == ".githooks"
    assert g("ls-files", "-s", "--", ".githooks/pre-push").stdout.startswith("100755 ")
    assert g("rev-parse", "--verify", "--quiet", "HEAD").returncode != 0


def test_package_templates_match_repository():
    src = REPO / "templates"
    shipped = sorted(p.relative_to(PKG_TEMPLATES).as_posix()
                     for p in PKG_TEMPLATES.rglob("*") if p.is_file())
    assert len(shipped) > 20
    for rel in shipped:
        assert (src / rel).read_bytes() == (PKG_TEMPLATES / rel).read_bytes(), rel
    proj = sorted(p.relative_to(src).as_posix() for p in (src / "project").rglob("*") if p.is_file())
    assert proj == [s for s in shipped if s.startswith("project/")]
    # The R package ships the same copies.
    rpkg = REPO / "r" / "inst" / "templates"
    assert sorted(p.relative_to(rpkg).as_posix() for p in rpkg.rglob("*") if p.is_file()) == shipped


def _rscript():
    cand = os.environ.get("RSCRIPT") or shutil.which("Rscript")
    if not cand:
        for p in sorted(Path("C:/Program Files/R").glob("R-*/bin/Rscript.exe")):
            cand = str(p)
    return cand


@pytest.mark.skipif(not _rscript(), reason="R not available")
def test_r_python_parity(tmp_path):
    """Both languages write the same files, byte for byte."""
    clone = fake_clone(tmp_path, cp._KINDS["official-stats"]["vendor"])
    for kind, fn in (("research", "create_research_project"),
                     ("official-stats", "create_official_stats_project")):
        # Same folder name: it fills the {{project_name}} placeholder.
        py_root, r_root = tmp_path / "py" / kind, tmp_path / "r" / kind
        getattr(m, fn)(py_root, "multi-producer", members=["jpazvd", "kbarnes"],
                       title="A Title", vendor=True, toolkit_source=clone, workflows=True)
        code = (
            f"suppressMessages(pkgload::load_all({str(REPO / 'r').replace(os.sep, '/')!r}, quiet = TRUE));"
            f"invisible({fn}({str(r_root).replace(os.sep, '/')!r}, collaboration = 'multi-producer',"
            " members = c('jpazvd', 'kbarnes'), title = 'A Title', vendor = TRUE,"
            f" toolkit_source = {str(clone).replace(os.sep, '/')!r}, workflows = TRUE, verbose = FALSE))"
        )
        res = subprocess.run([_rscript(), "--no-init-file", "-e", code],
                             capture_output=True, text=True)
        if res.returncode != 0 and "there is no package called" in res.stderr:
            pytest.skip("pkgload not installed")
        assert res.returncode == 0, res.stderr
        assert on_disk(py_root) == on_disk(r_root)
        for rel in on_disk(py_root):
            assert (py_root / rel).read_bytes() == (r_root / rel).read_bytes(), rel
