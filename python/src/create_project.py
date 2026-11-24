"""Scaffold a new research or official-statistics repository.

Python sibling of ``r/R/create_project.R``: the same files, byte for byte.

- :func:`create_research_project` -- papers, analysis, replication packages.
- :func:`create_official_stats_project` -- DW sector pipelines, SDMX /
  data.unicef.org publication, survey processing.

Both write ``.gitignore``, ``tools/check.R`` and the pre-push hook, a
testthat suite, ``cso_project.yml``, README / CONTRIBUTING skeletons and the
data or inputs README and manifest, from the templates the package ships in
``templates/`` (a byte-for-byte copy of the repository's ``templates/``,
kept in step by ``tools/sync_templates.py`` and a test). The scaffold is the
same whichever language creates it; its checks and tests are in R.

Handbook: chapter "Starting a repository". Stata: not provided.
"""

from __future__ import annotations

import datetime as _dt
import logging
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Union

import pandas as pd

# The git and release-tag helpers live in cso_toolkit_sync.py, which
# consumers vendor on its own; the scaffolders share them.
from .cso_toolkit_sync import (
    _cso_git_blob as _git_blob,
    _cso_git_out as _git_out,
    _cso_resolve_tag as _resolve_tag,
    _cso_toolkit_source as _toolkit_source,
    _cso_user as _user,
)

_log = logging.getLogger(__name__)

_COLLAB_MODELS = ("single-producer", "multi-producer")

_KINDS: Dict[str, dict] = {
    "research": {
        "fn": "create_research_project",
        # A paper's first scripts read data directly: the contract audit
        # reports them, and does not fail the checks, until the project moves
        # to dw_use() and sets AUDIT_MODE to "blocking".
        "audit_mode": "advisory",
        "deposit": False,
        "gitignore": "research-project.gitignore",
        "input_manifest": "data/input_manifest.csv",
        "source_dirs": 'SOURCE_DIRS <- c("R/functions")',
        "workflows": ["ci-hygiene.yml", "ci-contract-audit.yml", "ci-r-tests.yml",
                      "ci-manuscript.yml"],
        "vendor": ["dw_io.R", "dw_api.R", "cso_toolkit_sync.R", "dw_provenance.R",
                   "dw_deposit.R", "dw_project.R", "test_scripts.R", "zzz.R"],
    },
    "official-stats": {
        "fn": "create_official_stats_project",
        "audit_mode": "blocking",
        # The profile derives the deposit paths and checks the Z: mirror.
        "deposit": True,
        "gitignore": "official-stats.gitignore",
        "input_manifest": "inputs/input_manifest.csv",
        "source_dirs": "SOURCE_DIRS <- character(0)",
        "workflows": ["ci-hygiene.yml", "ci-contract-audit.yml", "ci-r-tests.yml"],
        "vendor": ["dw_io.R", "dw_api.R", "cso_toolkit_sync.R", "dw_provenance.R",
                   "dw_deposit.R", "dw_project.R", "test_scripts.R", "zzz.R",
                   "profile_helpers.R", "create_sector_script.R"],
    },
}

# tools/check.R needs these three in 00_functions/ (contract-audit, vintage).
_VENDOR_REQUIRED = ["dw_io.R", "cso_toolkit_sync.R", "test_scripts.R"]

# Exact template lines the scaffolders edit (same as the R sibling).
_CHECKS_LINE = '  CHECKS      = "tracked-data large-files secret-scan sidecars contract-audit vintage tests",'
_CHECKS_UNVENDORED = (
    "  # contract-audit and vintage need the vendored toolkit in 00_functions/:\n"
    "  # add them back here once it is vendored (see 00_functions/README.md).\n"
    '  CHECKS      = "tracked-data large-files secret-scan sidecars tests",'
)
_OUTPUT_DIRS_LINE = '  OUTPUT_DIRS = "",'
_OUTPUT_DIRS_OFFICIAL = '  OUTPUT_DIRS = "output outputs results wrk 013_wrkdata",'
_DATA_DIRS_LINE = '  DATA_DIRS   = "data inputs _apis _frozen",'
_DATA_DIRS_OFFICIAL = '  DATA_DIRS   = "data inputs _apis _frozen 011_rawdata",'
_AUDIT_PATHS_LINE = '  AUDIT_PATHS = "R",'
_AUDIT_MODE_LINE = '  AUDIT_MODE  = "blocking",'
_SOURCE_DIRS = 'SOURCE_DIRS <- c("R")'
_MEMBERS_EXAMPLE = "# members:\n#   - jpazevedo\n#   - kbarnes\n"
_DEPOSIT_BLOCK = "{{deposit_block}}\n"


def _edit(data: bytes, old: str, new: str, what: str, fn: str) -> bytes:
    """Replace the first exact occurrence of ``old``, or stop if it is absent."""
    s = data.decode("utf-8")
    if old not in s:
        raise RuntimeError(
            f"[cso_toolkit.{fn}] The shipped template {what} no longer contains "
            f"the line this function edits:\n   {old}\n"
            "  Fix: update the package (or report it at "
            "https://github.com/unicef-drp/cso-toolkit/issues); the template and "
            "the scaffolder are out of step."
        )
    return s.replace(old, new, 1).encode("utf-8")


def _fill(data: bytes, variables: Dict[str, str]) -> bytes:
    s = data.decode("utf-8")
    for key, value in variables.items():
        s = s.replace("{{" + key + "}}", value)
    return s.encode("utf-8")


def _templates_dir(toolkit_source: Optional[Path], fn: str) -> Path:
    cands = [Path(__file__).resolve().parent / "templates"]
    if toolkit_source is not None:
        cands.append(Path(toolkit_source) / "templates")
    for d in cands:
        if (d / "project" / "common" / "00_functions" / "README.md").is_file():
            return d
    raise FileNotFoundError(
        f"[cso_toolkit.{fn}] The project templates were not found.\n"
        "  Why: they ship with the installed cso_toolkit package (templates/), "
        "and this installation has neither them nor a toolkit clone.\n"
        "  Fix: install the package from a cso-toolkit clone "
        "(pip install <clone>/python), or pass toolkit_source=\"<clone>\"."
    )


def _project_files(kind: str, project_name: str, title: str, collaboration: str,
                   members: Sequence[str], vendored: dict, tpl: Path,
                   workflows: bool, fn: str) -> Dict[str, bytes]:
    k = _KINDS[kind]
    vendor_files = list(vendored["files"])
    today = _dt.date.today().strftime("%Y-%m-%d")
    variables = {"project_name": project_name, "title": title,
                 "collaboration": collaboration, "date": today,
                 "input_manifest": k["input_manifest"],
                 "sentinel": re.sub(r"[^A-Za-z0-9_]+", "_", project_name), "fn": fn}
    files: Dict[str, bytes] = {}

    for layer in ("common", kind):
        base = tpl / "project" / layer
        for p in sorted(base.rglob("*")):
            if p.is_file():
                files[p.relative_to(base).as_posix()] = _fill(p.read_bytes(), variables)

    # profile_<project>.R: one template for both kinds; official statistics
    # add the deposit paths and the Z: mirror check.
    deposit = (tpl / "profile" / "deposit.R").read_text(encoding="utf-8") if k["deposit"] else ""
    prof = _edit((tpl / "profile" / "profile.R").read_bytes(), _DEPOSIT_BLOCK, deposit,
                 "profile/profile.R", fn)
    files[f"profile_{project_name}.R"] = _fill(prof, variables)

    files[".gitignore"] = (tpl / "gitignore" / k["gitignore"]).read_bytes()
    files[".gitattributes"] = (tpl / "gitattributes" / "project.gitattributes").read_bytes()
    files[".githooks/pre-push"] = (tpl / "hooks" / "pre-push").read_bytes()
    # Check records (#174): the wrapper that also records, and the one
    # workflow on by default (pull requests into develop and main; no R).
    files["tools/check"] = (tpl / "tools" / "check").read_bytes()
    files[".checks/README.md"] = (tpl / "checks" / "README.md").read_bytes()
    files[".github/workflows/check-record.yml"] = (tpl / "workflows" / "check-record.yml").read_bytes()
    # AI coding agents (#173; handbook chapter "Working with AI coding agents"): one instructions file for
    # every agent (CLAUDE.md imports it), the decision log, and the shared
    # Claude Code settings (the plugin; no edits to the vendored copy).
    agents = (tpl / "agents" / "AGENTS.md").read_bytes()
    if kind == "official-stats":
        agents += (tpl / "agents" / "AGENTS-official-stats.md").read_bytes()
    files["AGENTS.md"] = _fill(agents, variables)
    files["CLAUDE.md"] = (tpl / "agents" / "CLAUDE.md").read_bytes()
    files["decisions.md"] = (tpl / "agents" / "decisions.md").read_bytes()
    files[".claude/settings.json"] = (tpl / "agents" / "settings.json").read_bytes()

    chk = (tpl / "tools" / "check.R").read_bytes()
    if kind == "official-stats":
        # The deposit layout's stages: 013_wrkdata is embargoed like any output
        # folder, 011_rawdata holds data like any input folder.
        chk = _edit(chk, _OUTPUT_DIRS_LINE, _OUTPUT_DIRS_OFFICIAL, "tools/check.R", fn)
        chk = _edit(chk, _DATA_DIRS_LINE, _DATA_DIRS_OFFICIAL, "tools/check.R", fn)
        chk = _edit(chk, _AUDIT_PATHS_LINE, '  AUDIT_PATHS = "01_dw_prep/012_codes",',
                    "tools/check.R", fn)
    chk = _edit(chk, _AUDIT_MODE_LINE, f'  AUDIT_MODE  = "{k["audit_mode"]}",',
                "tools/check.R", fn)
    if not vendor_files:
        chk = _edit(chk, _CHECKS_LINE, _CHECKS_UNVENDORED, "tools/check.R", fn)
    files["tools/check.R"] = chk

    files["tests/testthat.R"] = _edit(
        (tpl / "testthat" / "tests" / "testthat.R").read_bytes(),
        _SOURCE_DIRS, k["source_dirs"], "testthat/tests/testthat.R", fn)
    files["tests/testthat/helper-project.R"] = (
        tpl / "testthat" / "tests" / "testthat" / "helper-project.R").read_bytes()

    proj = (tpl / "cso_project.yml").read_bytes()
    for line in ("\ncollaboration: ", "\ncollaboration_since: "):
        _edit(proj, line, line, "cso_project.yml", fn)
    s = proj.decode("utf-8")
    s = re.sub(r"\ncollaboration: [^\n]*", "\ncollaboration: " + collaboration, s, count=1)
    s = re.sub(r"\ncollaboration_since: [^\n]*", "\ncollaboration_since: " + today, s, count=1)
    proj = s.encode("utf-8")
    if members:
        proj = _edit(proj, _MEMBERS_EXAMPLE,
                     "members:\n" + "".join(f"  - {m}\n" for m in members),
                     "cso_project.yml", fn)
    files["cso_project.yml"] = proj

    if workflows:
        for w in k["workflows"]:
            files[f".github/workflows/{w}"] = (tpl / "workflows" / w).read_bytes()

    if vendor_files:
        for f in vendor_files:
            files[f"00_functions/{f}"] = vendored["files"][f]
        manifest = [
            "# .toolkit_manifest.yml -- the cso-toolkit vintage this repository vendors.",
            f"# Written by {fn}(); fields: cso-toolkit templates/.toolkit_manifest.yml.",
            "# Update it every time you re-vendor, in the same pull request.",
            'source: "unicef-drp/cso-toolkit"',
            f'pulled_version: "{vendored["tag"]}"',
            f'pulled_commit: "{vendored["sha"]}"',
            f'pulled_date: "{today}"',
            f'pulled_by: "{_user()}"',
            f'# target_version: "{vendored["tag"]}"   # optional: warn when pulled_version is behind',
            "",
            "# Files vendored from cso-toolkit/r/R/ at pulled_version into 00_functions/",
            "vendored:",
            *[f"  - {f}" for f in vendor_files],
            "",
            "# Vendored files edited locally (cso_toolkit_pull() skips them).",
            "local_edits: []",
        ]
        files["00_functions/.toolkit_manifest.yml"] = ("\n".join(manifest) + "\n").encode("utf-8")
    return {key: files[key] for key in sorted(files)}


def _git_setup(path: Path, fn: str) -> None:
    def run(*args: str) -> None:
        res = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(
                f"[cso_toolkit.{fn}] The files were written, but `git {' '.join(args)}` "
                f"failed:\n   {(res.stderr or res.stdout).strip()}\n"
                "  Fix: run the git steps by hand (README.md > Quick start)."
            )

    if not (path / ".git").exists():
        run("init", "--quiet")
        # Two trunks: work starts on develop; main is created at the first release.
        run("symbolic-ref", "HEAD", "refs/heads/develop")
        _log.info("[%s] git init: first branch develop", fn)
    run("config", "core.hooksPath", ".githooks")
    # Stage the hook with its executable bit, so it runs on macOS and Linux
    # clones too (Windows does not record the bit otherwise).
    run("add", "--chmod=+x", "--", ".githooks/pre-push", "tools/check")
    _log.info("[%s] git: core.hooksPath = .githooks; .githooks/pre-push and tools/check "
              "staged as executable", fn)


def _create_project(kind: str, path: Union[str, Path], collaboration: Optional[str],
                    members: Optional[Sequence[str]], title: Optional[str],
                    vendor: Union[bool, Sequence[str]],
                    toolkit_source: Optional[Union[str, Path]],
                    toolkit_version: Optional[str], workflows: bool,
                    git: bool, overwrite: bool) -> pd.DataFrame:
    k = _KINDS[kind]
    fn = k["fn"]
    if not isinstance(path, (str, Path)) or not str(path):
        raise ValueError(
            f"[cso_toolkit.{fn}] `path` must be one folder path.\n"
            '  Fix: pass the folder of the new repository, e.g. "C:/GitHub/my-paper".'
        )
    root = Path(path)
    if root.exists() and not root.is_dir():
        raise NotADirectoryError(
            f"[cso_toolkit.{fn}] {root} is a file, not a folder.\n"
            "  Fix: pass the folder of the new repository."
        )
    if collaboration not in _COLLAB_MODELS:
        raise ValueError(
            f'[cso_toolkit.{fn}] `collaboration` must be "single-producer" or '
            '"multi-producer"; it has no default.\n'
            "  Why: how many people may produce results is a project decision, "
            "committed in cso_project.yml, and the toolkit does not guess it (as "
            "dw_mode has no default).\n"
            '  Fix: pass collaboration="single-producer" (one producer, the others '
            'review) or "multi-producer" (several co-authors produce).'
        )
    members = [str(m) for m in members] if members else []
    bad = [m for m in members if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", m)]
    if bad:
        raise ValueError(
            f"[cso_toolkit.{fn}] Member handle(s) not usable as plain YAML: "
            f"{', '.join(repr(b) for b in bad)}\n"
            "  Fix: pass user names or GitHub handles (letters, digits, '.', '_', '-')."
        )
    project_name = root.resolve().name
    if title is None:
        title = project_name

    if vendor is True:
        vendor_files = list(k["vendor"])
    elif isinstance(vendor, (list, tuple)):
        vendor_files = list(dict.fromkeys([*_VENDOR_REQUIRED, *vendor]))
    else:
        vendor_files = []
    src: Optional[Path] = Path(toolkit_source) if toolkit_source else None
    vendored: dict = {"files": {}, "tag": None, "sha": None}
    if vendor_files:
        src = _toolkit_source(toolkit_source, fn)
        # Always a release tag, read from git history: never the working tree,
        # which may be on another branch or carry local edits.
        rel = _resolve_tag(src, toolkit_version, fn)
        blobs = {f: _git_blob(src, rel["sha"], f"r/R/{f}") for f in vendor_files}
        absent = [f for f, b in blobs.items() if b is None]
        # The default set may name helpers newer than an older tag: those are
        # skipped (and named). A file the caller listed, or one that
        # tools/check.R needs, must be there.
        optional = [f for f in absent if f not in _VENDOR_REQUIRED] if vendor is True else []
        missing = [f for f in absent if f not in optional]
        if missing:
            raise FileNotFoundError(
                f"[cso_toolkit.{fn}] Not in r/R/ at {rel['tag']} ({rel['sha'][:7]}): "
                f"{', '.join(missing)}\n"
                "  Nothing was written.\n"
                "  Fix: check the file names, or pass a `toolkit_version` that has them."
            )
        if optional:
            _log.info("[%s] not in %s, so not vendored: %s (re-vendor from a later "
                      "release to add them)", fn, rel["tag"], ", ".join(optional))
        vendored = {"files": {f: b for f, b in blobs.items() if b is not None},
                    "tag": rel["tag"], "sha": rel["sha"]}
    if git and shutil.which("git") is None:
        raise RuntimeError(
            f"[cso_toolkit.{fn}] git=True, but git is not on the PATH.\n"
            "  Fix: install git, or pass git=False and run git init yourself."
        )
    tpl = _templates_dir(src, fn)
    _log.debug("[%s] templates: %s; toolkit source: %s %s", fn, tpl, src,
               f"at {vendored['tag']} ({vendored['sha']})" if vendored["tag"] else "")

    files = _project_files(kind, project_name, title, collaboration, members,
                           vendored, tpl, workflows, fn)

    # Decide every file before writing any: never a half-written project.
    dirs = [rel for rel in files if (root / rel).is_dir()]
    if dirs:
        raise FileExistsError(
            f"[cso_toolkit.{fn}] These paths are folders under {path}, where the "
            "project needs files:\n   " + "\n   ".join(dirs) + "\n"
            "  Nothing was written.\n"
            "  Fix: move the folders away, or choose another `path`."
        )
    status: List[str] = []
    for rel, data in files.items():
        target = root / rel
        if not target.exists():
            status.append("written")
        elif target.read_bytes() == data:
            status.append("unchanged")
        else:
            status.append("conflict")
    conflicts = [rel for rel, st in zip(files, status) if st == "conflict"]
    if conflicts and not overwrite:
        raise FileExistsError(
            f"[cso_toolkit.{fn}] {len(conflicts)} file(s) already exist under {path} "
            "with different content:\n   " + "\n   ".join(conflicts) + "\n"
            "  Nothing was written.\n"
            "  Fix: choose an empty folder, move those files away, or pass "
            "overwrite=True to replace them."
        )
    status = ["overwritten" if st == "conflict" else st for st in status]

    for (rel, data), st in zip(files.items(), status):
        if st == "unchanged":
            continue
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    if os.name != "nt":
        for rel in (".githooks/pre-push", "tools/check"):
            exe = root / rel
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    if git:
        _git_setup(root, fn)

    out = pd.DataFrame({"path": list(files), "status": status})
    _log.info("[%s] %s project at %s: %d file(s) written, %d overwritten, %d unchanged",
              fn, kind, root.resolve(), status.count("written"),
              status.count("overwritten"), status.count("unchanged"))
    if vendored["tag"]:
        _log.info("[%s] vendored %d helper(s) from cso-toolkit %s (commit %s)", fn,
                  len(vendored["files"]), vendored["tag"], vendored["sha"][:7])
    _log.info("[%s] check records: run `sh tools/check --record` before each push; on "
              "GitHub require the status `check-record` and up-to-date branches for develop "
              "and main (handbook chapter 'Checks and CI')", fn)
    _log.info("[%s] next: README.md > Quick start%s", fn,
              "" if vendor_files else
              "; vendor the toolkit into 00_functions/ (00_functions/README.md)")
    return out


def create_research_project(
    path: Union[str, Path],
    collaboration: Optional[str] = None,
    *,
    members: Optional[Sequence[str]] = None,
    title: Optional[str] = None,
    vendor: Union[bool, Sequence[str]] = False,
    toolkit_source: Optional[Union[str, Path]] = None,
    toolkit_version: Optional[str] = None,
    workflows: bool = False,
    git: bool = False,
    overwrite: bool = False,
) -> pd.DataFrame:
    """Create a new research repository (paper, analysis, replication package).

    Writes the skeleton of a research repository into ``path``, following the
    toolkit's conventions: data never enter git while their
    ``.provenance.json`` sidecars and an input manifest do; results (small
    tables and figures) are committed with their sidecars; checks run
    locally with one command (``Rscript --no-init-file tools/check.R``); two
    trunks (``develop``, ``main``). The files are the same, byte for byte,
    as R's ``create_research_project()`` writes.

    Layout::

        .gitignore               templates/gitignore/research-project.gitignore
        .gitattributes           LF for the hook, vendored helpers and sidecars
        profile_<project>.R      sourced first: user, dw_mode, vendored helpers
        .githooks/pre-push       requires a check record before every push
        cso_project.yml          collaboration model (committed)
        README.md, CONTRIBUTING.md
        00_functions/README.md   (+ helpers and .toolkit_manifest.yml if vendored)
        R/README.md              numbered analysis scripts; R/functions/ for tests
        data/README.md, data/input_manifest.csv, data/provenance/README.md
        output/README.md         tables and figures, with sidecars
        paper/README.md, references/README.md, docs/README.md
        tests/testthat.R, tests/testthat/helper-project.R, test-project.R
        tools/check.R, tools/check   the checks; sh tools/check --record
        .checks/README.md        check records (.checks/<content-hash>.json)
        .github/workflows/check-record.yml   verifies the record on PRs (always)
        .github/workflows/*.yml  the others only with workflows=True
        AGENTS.md, CLAUDE.md     instructions for AI coding agents (CLAUDE.md: @AGENTS.md)
        decisions.md             decisions and the record of AI use
        .claude/settings.json    Claude Code: the cso-toolkit plugin; no edits to 00_functions/

    Nothing is written if any target file already exists with different
    content, unless ``overwrite=True``; a file that already holds exactly the
    bytes to be written is left alone (``"unchanged"``).

    Parameters
    ----------
    path
        Folder of the new repository; created if missing.
    collaboration
        Required (no default, as ``dw_mode`` has none): ``"single-producer"``
        or ``"multi-producer"``. Written to ``cso_project.yml``; change it
        later with :func:`dw_set_collaboration`.
    members
        Collaborators' user names or GitHub handles (informational).
    title
        Title for the README; ``None`` uses the folder name.
    vendor
        ``False`` (default), ``True``, or a list of file names. ``True``
        copies the default helper set, as it is at the release tag
        ``toolkit_version``, from a cso-toolkit clone's ``r/R/`` into
        ``00_functions/`` and writes ``.toolkit_manifest.yml``
        (``pulled_version`` = the tag, ``pulled_commit`` = its commit).
        Default helpers the tag does not have yet are skipped and logged. A
        list names the files, which must all exist at the tag; ``dw_io.R``,
        ``cso_toolkit_sync.R`` and ``test_scripts.R`` are always added. With
        ``False``, ``tools/check.R`` leaves out ``contract-audit`` and
        ``vintage`` until the helpers are vendored.
    toolkit_source
        Root of a git clone of cso-toolkit, with its tags. Its working tree
        may be on any branch and carry local edits: the files are read from
        the tag's commit, never from the working tree. ``None`` uses
        ``CSO_TOOLKIT_ROOT``, else the source checkout of an editable install.
    toolkit_version
        The release tag to vendor, e.g. ``"v0.9.1"`` (``"0.9.1"`` is read as
        ``"v0.9.1"``). ``None`` (default) takes the clone's latest release
        tag (pre-release tags such as ``v1.0.0-rc1`` are passed over).
    workflows
        Also write the opt-in GitHub Actions workflows to
        ``.github/workflows/``. Default ``False``. ``check-record.yml`` is
        always written: it verifies the local check record on pull
        requests, without running R.
    git
        ``True`` runs ``git init`` (when ``path`` is not a repository) with
        ``develop`` as the first branch, sets ``core.hooksPath`` to
        ``.githooks`` and stages the hook and ``tools/check`` with their
        executable bit. Never
        commits, creates a remote or pushes.
    overwrite
        Replace existing files whose content differs. Default ``False``.

    Returns
    -------
    pandas.DataFrame
        One row per file: ``path`` (relative) and ``status`` (``"written"``,
        ``"overwritten"`` or ``"unchanged"``).

    Raises
    ------
    ValueError
        ``collaboration`` missing or unknown; unusable member handles.
    FileExistsError
        A target file exists with different content and ``overwrite=False``.
    FileNotFoundError
        Vendoring without a git clone to copy from, or a requested file is
        not at the tag.
    LookupError
        The tag does not exist in the clone, or the clone has no release tag.
    """
    return _create_project("research", path, collaboration, members, title, vendor,
                           toolkit_source, toolkit_version, workflows, git, overwrite)


def create_official_stats_project(
    path: Union[str, Path],
    collaboration: Optional[str] = None,
    *,
    members: Optional[Sequence[str]] = None,
    title: Optional[str] = None,
    vendor: Union[bool, Sequence[str]] = False,
    toolkit_source: Optional[Union[str, Path]] = None,
    toolkit_version: Optional[str] = None,
    workflows: bool = False,
    git: bool = False,
    overwrite: bool = False,
) -> pd.DataFrame:
    """Create a new official-statistics repository (production pipeline).

    For a DW sector pipeline, an SDMX or data.unicef.org publication pipeline
    or a survey-processing repository. Outputs live in the deposit and are
    embargoed until publication, so the ``.gitignore`` ignores output folders
    outright, ``tools/check.R`` sets ``OUTPUT_DIRS`` to fail on anything
    tracked in them (``013_wrkdata`` included), ``DATA_DIRS`` to fail on data
    tracked in ``011_rawdata`` and ``AUDIT_PATHS`` to ``01_dw_prep/012_codes``,
    and the repository commits a release record under ``releases/<vintage>/``
    after publication. The layout follows DW-Production and the deposit's
    stage numbering. Same files as R's ``create_official_stats_project()``.

    Layout::

        .gitignore                templates/gitignore/official-stats.gitignore
        .gitattributes            LF for the hook, vendored helpers and sidecars
        profile_<project>.R       sourced first: user, dw_mode, deposit paths,
                                  Z: mirror, vendored helpers
        .githooks/pre-push        requires a check record before every push
        cso_project.yml           collaboration model (committed)
        README.md, CONTRIBUTING.md
        _config_template/user_config.yml   placeholder per-person configuration
        00_documentation/README.md
        00_functions/README.md    (+ helpers and .toolkit_manifest.yml if vendored)
        01_dw_prep/README.md      the stages: what each holds, what reaches git
        01_dw_prep/010_metadata/README.md   reference metadata, committed
        01_dw_prep/011_rawdata/README.md    local raw inputs: ignored, sidecars kept
        01_dw_prep/012_codes/README.md      pipeline code, one folder per sector
                                  (013_wrkdata/ has no tracked file: embargoed)
        inputs/README.md, inputs/input_manifest.csv
        releases/README.md        release records, committed after publication
        tests/testthat.R, tests/testthat/helper-project.R, test-project.R
        tools/check.R             OUTPUT_DIRS, DATA_DIRS and AUDIT_PATHS set
        tools/check               the wrapper; sh tools/check --record
        .checks/README.md         check records (.checks/<content-hash>.json)
        .github/workflows/check-record.yml   verifies the record on PRs (always)
        .github/workflows/*.yml   the others only with workflows=True (no manuscript job)
        AGENTS.md, CLAUDE.md      instructions for AI coding agents, with the embargo section
        decisions.md              decisions and the record of AI use
        .claude/settings.json     Claude Code: the cso-toolkit plugin; no edits to 00_functions/

    Parameters, return value and errors are those of
    :func:`create_research_project`. With ``vendor=True`` the default helper
    set adds ``profile_helpers.R`` and ``create_sector_script.R``.
    """
    return _create_project("official-stats", path, collaboration, members, title,
                           vendor, toolkit_source, toolkit_version, workflows, git, overwrite)
