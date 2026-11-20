"""Project-level collaboration model (``cso_project.yml``).

Python port of ``r/R/dw_project.R``: same file, same keys, same error
envelopes, same sidecar fields.

Session MODES stay per person: ``dw_mode`` (producer | reviewer) comes from
each user's ``~/.config/user_config.yml``.  How many people may PRODUCE is a
property of the PROJECT, committed in the repository as ``cso_project.yml``::

    schema: cso_project/1
    collaboration: single-producer | multi-producer
    collaboration_since: 2026-11-20
    members:            # optional, informational
      - jpazevedo

An absent file means ``single-producer``: the toolkit behaves exactly as it
did before the file existed.  In a ``multi-producer`` project,
:func:`cso_toolkit.dw_save` guards an existing output against out-of-band
changes and concurrent writes, and records the lineage (previous sha256 /
user / time, git branch and commit) in the provenance sidecar.

* :func:`dw_collaboration` resolves (once per session) and returns the model.
* :func:`dw_set_collaboration` writes ``cso_project.yml`` and baselines the
  existing sidecars, in one reviewed commit.

Session state (in :mod:`cso_toolkit._state`, like ``dw_mode``):
``dw_collaboration_model``, ``dw_project_file``, ``dw_session_start``.
"""

from __future__ import annotations

import datetime as _dt
import getpass
import hashlib
import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Union

from . import _state

_log = logging.getLogger(__name__)

_COLLAB_MODELS = ("single-producer", "multi-producer")
_PROJECT_FILE = "cso_project.yml"
_PROJECT_SCHEMA = "cso_project/1"
_TS_FORMAT = "%Y-%m-%dT%H:%M:%S%z"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    """Current UTC time in the sidecar ``written_at`` format."""
    return _dt.datetime.now(_dt.timezone.utc).strftime(_TS_FORMAT)


def _parse_iso(value: Any) -> Optional[_dt.datetime]:
    """Parse a sidecar timestamp (``YYYY-MM-DDTHH:MM:SS+0000``); None if not."""
    if not isinstance(value, str) or not value:
        return None
    try:
        return _dt.datetime.strptime(value, _TS_FORMAT)
    except ValueError:
        return None


def _current_user() -> str:
    """The user name recorded in sidecars (same source as ``_write_provenance``)."""
    return os.environ.get("USERNAME") or getpass.getuser()


def _str1(value: Any) -> Optional[str]:
    """A non-empty string, or None (for sidecar fields that may be missing)."""
    return value if isinstance(value, str) and value else None


def _sha256_file(path: Union[str, Path]) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def _session_start() -> str:
    """Session start time (ISO-8601 UTC); set on first use."""
    start = _state._get("dw_session_start")
    if isinstance(start, str) and start:
        return start
    start = _now_iso()
    _state.dw_session_start = start
    return start


def _find_project_file(start: Union[str, Path]) -> Optional[str]:
    """Walk up from ``start`` to the first ``cso_project.yml``.

    Stops at the repository root (the first folder holding ``.git``) so a
    repository without the file never picks up a parent folder's.
    """
    d = Path(start).resolve(strict=False)
    if d.exists() and not d.is_dir():
        d = d.parent
    while True:
        cand = d / _PROJECT_FILE
        if cand.exists():
            return str(cand).replace("\\", "/")
        if (d / ".git").exists():
            return None
        if d.parent == d:
            return None
        d = d.parent


def _read_project(file: Union[str, Path]) -> Dict[str, Any]:
    """Read and validate a ``cso_project.yml``."""
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover - PyYAML is an optional dep
        raise ImportError(
            f"[cso_toolkit.dw_collaboration] Reading {file} needs PyYAML.\n"
            "  Fix: `pip install PyYAML` (or `pip install cso-toolkit[yaml]`)."
        ) from exc
    try:
        with open(file, encoding="utf-8") as f:
            proj = yaml.safe_load(f)  # cso-allow: io-yaml
    except yaml.YAMLError as exc:
        raise ValueError(
            f"[cso_toolkit.dw_collaboration] {file} is not valid YAML.\n"
            f"  Parser said: {exc}\n"
            "  Fix: restore the file from version control, or rewrite it "
            "with dw_set_collaboration()."
        ) from exc
    if proj is None:
        proj = {}
    if not isinstance(proj, dict):
        raise ValueError(
            f"[cso_toolkit.dw_collaboration] {file} must be a YAML mapping "
            "(key: value lines).\n"
            "  Fix: start from templates/cso_project.yml, or rewrite it with "
            "dw_set_collaboration()."
        )
    schema = proj.get("schema", _PROJECT_SCHEMA)
    if str(schema) != _PROJECT_SCHEMA:
        raise ValueError(
            f"[cso_toolkit.dw_collaboration] {file} declares schema "
            f"'{schema}'; this toolkit reads '{_PROJECT_SCHEMA}'.\n"
            "  Fix: upgrade cso-toolkit, or correct the `schema:` line."
        )
    collab = proj.get("collaboration", "single-producer")
    if collab is None:
        collab = "single-producer"
    if collab not in _COLLAB_MODELS:
        raise ValueError(
            f"[cso_toolkit.dw_collaboration] {file} sets `collaboration: "
            f"{collab}`; it must be 'single-producer' or 'multi-producer'.\n"
            "  Fix: correct the value, or set it with dw_set_collaboration()."
        )
    proj["schema"] = _PROJECT_SCHEMA
    proj["collaboration"] = collab
    since = proj.get("collaboration_since")
    if since is not None:
        # PyYAML turns an unquoted date into datetime.date; R reads a string.
        proj["collaboration_since"] = (
            since.isoformat() if hasattr(since, "isoformat") else str(since)
        )
    members = proj.get("members")
    if members is not None:
        if isinstance(members, (list, tuple)):
            proj["members"] = [str(x) for x in members]
        else:
            proj["members"] = [str(members)]
    proj["file"] = str(file)
    return proj


# ---------------------------------------------------------------------------
# dw_collaboration — resolve the model once per session
# ---------------------------------------------------------------------------

def dw_collaboration(root: Optional[Union[str, Path]] = None,
                     refresh: bool = False) -> str:
    """Resolve the collaboration model of the current project.

    Returns ``"single-producer"`` or ``"multi-producer"``.  The model is a
    **project** property, committed in ``cso_project.yml`` at the
    repository root, the same for every collaborator; the session **mode**
    (``dw_mode``: producer or reviewer) stays per person.  An absent file
    means ``"single-producer"``, the toolkit's behaviour before the file
    existed.

    The model is resolved once per session and cached in
    :mod:`cso_toolkit._state` (``dw_collaboration_model``,
    ``dw_project_file``), together with the session start time
    (``dw_session_start``) that :func:`cso_toolkit.dw_save` uses to detect
    concurrent writes.  Discovery walks up from ``root`` (default:
    ``_state.rootFolder``, else the working directory) to the first
    ``cso_project.yml``, stopping at the repository root (the first folder
    holding ``.git``).

    Parameters
    ----------
    root
        Folder to start the search from.  Passing it (or ``refresh=True``)
        re-resolves and re-caches the model.
    refresh
        Ignore the cached value and read the file again.

    Returns
    -------
    str
        ``"single-producer"`` or ``"multi-producer"``.

    Raises
    ------
    ValueError
        ``[cso_toolkit.dw_collaboration]`` envelope when the file is not
        valid YAML, declares another schema, or sets an unknown model.
    """
    cached = _state._get("dw_collaboration_model")
    if root is None and not refresh and cached in _COLLAB_MODELS:
        return cached
    start = root or _state._get("rootFolder") or os.getcwd()
    file = _find_project_file(start)
    proj = _read_project(file) if file else None
    model = proj["collaboration"] if proj else "single-producer"
    _state.dw_collaboration_model = model
    _state.dw_project_file = file
    _session_start()
    _log.debug("[dw_collaboration] start=%s file=%s model=%s", start, file, model)
    return model


# ---------------------------------------------------------------------------
# dw_save pre-flight
# ---------------------------------------------------------------------------

def _git_info(path: Union[str, Path]) -> Dict[str, Optional[str]]:
    """Best-effort git branch and commit of the folder holding ``path``."""
    folder = str(Path(path).resolve(strict=False).parent)

    def run(*args: str) -> Optional[str]:
        try:
            proc = subprocess.run(["git", "-C", folder, *args],
                                  capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return None
        out = proc.stdout.strip()
        return out if proc.returncode == 0 and out and "\n" not in out else None

    return {"branch": run("rev-parse", "--abbrev-ref", "HEAD"),
            "commit": run("rev-parse", "HEAD")}


def _collab_preflight(path: str, takeover: bool = False,
                      is_reviewer: bool = False) -> Optional[Dict[str, Any]]:
    """Multi-producer guards + lineage for :func:`cso_toolkit.dw_save`.

    Applies the out-of-band and concurrent-write guards (non-reviewer
    sessions only) and returns the lineage fields for the new sidecar.
    Returns ``None`` in a single-producer project, so the sidecar is
    unchanged.
    """
    if dw_collaboration() != "multi-producer":
        return None
    me = _current_user()
    sidecar = Path(f"{path}.provenance.json")
    file_sha: Optional[str] = None
    prev: Optional[dict] = None
    if Path(path).exists():
        file_sha = _sha256_file(path)
        if sidecar.exists():
            try:
                with open(sidecar, encoding="utf-8") as f:
                    prev = json.load(f)
            except (OSError, ValueError):
                prev = None
            if not isinstance(prev, dict):
                prev = None
    prev_sha = _str1(prev.get("sha256")) if prev else None
    prev_user = _str1(prev.get("user")) if prev else None
    prev_at = _str1(prev.get("written_at")) if prev else None
    fired: List[str] = []

    if not is_reviewer and prev is not None:
        why: List[str] = []
        if prev_sha and file_sha and prev_sha != file_sha:
            fired.append("out_of_band")
            why.append(
                f"  Why (out-of-band change): the file's SHA-256 "
                f"({file_sha[:12]}) no longer matches its provenance sidecar "
                f"({prev_sha[:12]}): someone changed it without dw_save(), so "
                "replacing it now would discard a change nobody recorded."
            )
        start = _session_start()
        prev_dt, start_dt = _parse_iso(prev_at), _parse_iso(start)
        if (prev_user and prev_user != me and prev_dt is not None
                and start_dt is not None and prev_dt > start_dt):
            fired.append("concurrent")
            why.append(
                f"  Why (concurrent write): {prev_user} wrote it at {prev_at}, "
                f"after this session started ({start}); two producers writing "
                "the same output in the same window would silently overwrite "
                "each other."
            )
        if fired and not takeover:
            raise PermissionError(
                "[cso_toolkit.dw_save] Multi-producer project: refusing to "
                f"replace {path}.\n" + "\n".join(why) + "\n"
                "  Fix:\n"
                "    1. Reconcile first: sync or pull the other change, check "
                "the file's history (git log, the sidecar's user and "
                "written_at), and re-run, OR\n"
                "    2. If you have checked it and mean to replace it, pass "
                "`takeover=True`; the takeover is recorded in the new sidecar."
            )
        if fired:
            _log.info("[dw_save] takeover: replacing %s despite %s (recorded "
                      "in the sidecar)", Path(path).name, " + ".join(fired))
        elif prev_user and prev_user != me and "baseline" not in prev:
            _log.info("[dw_save] note: %s was last written by %s%s; your write "
                      "follows theirs in its lineage.", Path(path).name,
                      prev_user, f" at {prev_at}" if prev_at else "")

    git = _git_info(path)
    lineage: Dict[str, Any] = {
        "collaboration": "multi-producer",
        "previous_sha256": file_sha or prev_sha,
        "previous_user": prev_user,
        "previous_written_at": prev_at,
        "git_branch": git["branch"],
        "git_commit": git["commit"],
    }
    if takeover:
        lineage["takeover"] = {"user": me, "at": _now_iso(),
                               "overrode": list(fired)}
    return lineage


# ---------------------------------------------------------------------------
# dw_set_collaboration
# ---------------------------------------------------------------------------

def _baseline_text(txt: str, baseline: Dict[str, str]) -> Optional[str]:
    """Insert ``"baseline": {...}`` into a sidecar's JSON text, byte-preserving.

    Returns None when the sidecar is skipped (not a JSON object, already
    baselined, or written under a multi-producer project).
    """
    try:
        parsed = json.loads(txt)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    if "baseline" in parsed or "collaboration" in parsed:
        return None
    pos = txt.rfind("}")
    if pos < 0:
        return None
    nl = "\r\n" if "\r\n" in txt else "\n"
    before = txt[:pos].rstrip()
    after = txt[pos:]

    def val(x: str) -> str:
        return json.dumps(x, ensure_ascii=False)

    member = (
        f'  "baseline": {{{nl}'
        f'    "collaboration": {val(baseline["collaboration"])},{nl}'
        f'    "at": {val(baseline["at"])},{nl}'
        f'    "by": {val(baseline["by"])}{nl}'
        "  }"
    )
    sep = nl if before.endswith("{") else "," + nl
    out = before + sep + member + nl + after
    # Self-check: the result parses and every original field is unchanged.
    try:
        chk = json.loads(out)
    except ValueError:
        return None
    if {k: chk.get(k) for k in parsed} != parsed:
        return None
    return out


def _project_yaml(model: str, since: str, members: Optional[Sequence[str]] = None,
                  extra: Optional[Dict[str, Any]] = None) -> str:
    """Render ``cso_project.yml`` text (identical in R and Python)."""
    lines = [
        "# cso_project.yml -- project-level cso-toolkit settings. Commit this file.",
        "# Session modes (dw_mode: producer | reviewer) stay per person in",
        "# ~/.config/user_config.yml; this file says how many people may produce.",
        "# Change it with dw_set_collaboration() in one reviewed pull request.",
        f"schema: {_PROJECT_SCHEMA}",
        f"collaboration: {model}",
        f"collaboration_since: {since}",
    ]
    if members:
        lines.append("members:")
        lines.extend(f"  - {m}" for m in members)
    if extra:
        import yaml
        lines.append(yaml.safe_dump(dict(extra), sort_keys=False).rstrip("\n"))
    return "\n".join(lines) + "\n"


def dw_set_collaboration(
    model: str,
    root: Optional[Union[str, Path]] = None,
    members: Optional[Sequence[str]] = None,
    baseline: bool = True,
) -> Dict[str, Any]:
    """Set the project's collaboration model (``cso_project.yml``).

    Writes or updates ``cso_project.yml`` at ``root`` and, with
    ``baseline=True``, adds a ``baseline`` object (``collaboration``,
    ``at``, ``by``) to every existing ``*.provenance.json`` under ``root``.
    The baseline marks artefacts that predate the switch as
    **project-owned**, so the first multi-producer write over them is not
    reported as a change of producer and their lineage chain starts
    cleanly.  The baseline is inserted as text: ``sha256`` and every other
    field of the sidecar are left byte-for-byte as they were.

    Idempotent: a second call with the same arguments changes nothing.
    Commit the result as one reviewed pull request, so every collaborator
    switches at the same commit.

    Parameters
    ----------
    model
        ``"single-producer"`` or ``"multi-producer"``.
    root
        Repository root that holds (or will hold) ``cso_project.yml``.
        Default: ``_state.rootFolder``, else the working directory.
    members
        Informational list of collaborators' user names or handles.
        ``None`` keeps the current list.
    baseline
        Add the ``baseline`` object to existing sidecars.

    Returns
    -------
    dict
        ``project_file``, ``collaboration``, ``project_file_changed``,
        ``sidecars_found``, ``sidecars_updated``, ``updated`` (paths).

    Raises
    ------
    PermissionError
        In reviewer mode (the call writes).
    ValueError
        For an unknown ``model``.
    FileNotFoundError
        When ``root`` does not exist.
    """
    if model not in _COLLAB_MODELS:
        raise ValueError(
            f"[cso_toolkit.dw_set_collaboration] Unknown collaboration model "
            f"{model!r}.\n"
            "  Fix: pass 'single-producer' or 'multi-producer'."
        )
    if _state._get("dw_mode") == "reviewer":
        raise PermissionError(
            "[cso_toolkit.dw_set_collaboration] Reviewer mode cannot change "
            "the project's collaboration model: the call writes "
            "cso_project.yml and the provenance sidecars.\n"
            "  Fix: run it in a producer session, then open one pull request "
            "with the result for review."
        )
    root_path = Path(root or _state._get("rootFolder") or os.getcwd())
    if not root_path.is_dir():
        raise FileNotFoundError(
            f"[cso_toolkit.dw_set_collaboration] Folder not found: {root_path}\n"
            "  Fix: pass the repository root as `root`."
        )
    file = root_path / _PROJECT_FILE
    me = _current_user()
    now = _now_iso()

    # --- cso_project.yml ---
    old = _read_project(file) if file.exists() else None
    keep_members = (old or {}).get("members") if members is None else [str(m) for m in members]
    changed = (old is None or old["collaboration"] != model
               or (members is not None and old.get("members") != keep_members))
    if changed:
        if old is not None and old["collaboration"] == model and old.get("collaboration_since"):
            since = old["collaboration_since"]
        else:
            since = _dt.date.today().isoformat()
        extra = {} if old is None else {
            k: v for k, v in old.items()
            if k not in ("schema", "collaboration", "collaboration_since", "members", "file")
        }
        with open(file, "w", encoding="utf-8", newline="\n") as f:
            f.write(_project_yaml(model, since, keep_members, extra))
        _log.info("[dw_set_collaboration] wrote %s: collaboration = %s", file, model)
    else:
        _log.info("[dw_set_collaboration] %s already sets collaboration = %s; "
                  "unchanged", file, model)

    # --- baseline the existing sidecars ---
    sidecars = sorted(
        p for p in root_path.rglob("*.provenance.json")
        if ".git" not in p.relative_to(root_path).parts
    )
    updated: List[str] = []
    if baseline:
        bl = {"collaboration": model, "at": now, "by": me}
        for sc in sidecars:
            try:
                raw = sc.read_bytes()
                new = _baseline_text(raw.decode("utf-8"), bl)
            except (OSError, UnicodeDecodeError):
                new = None
            if new is None:
                continue
            tmp = sc.with_name(sc.name + ".tmp")
            try:
                tmp.write_bytes(new.encode("utf-8"))
                tmp.replace(sc)
            except OSError as exc:
                tmp.unlink(missing_ok=True)
                import warnings
                warnings.warn(
                    f"[cso_toolkit.dw_set_collaboration] Could not update {sc} "
                    f"({exc}).\n"
                    "  Fix: close any program holding the file and run "
                    "dw_set_collaboration() again (it skips sidecars already "
                    "baselined).",
                    stacklevel=2,
                )
                continue
            updated.append(str(sc).replace("\\", "/"))
        _log.info("[dw_set_collaboration] baselined %d of %d provenance "
                  "sidecar(s) under %s", len(updated), len(sidecars), root_path)

    # The session now follows the new setting.
    _state.dw_collaboration_model = model
    _state.dw_project_file = str(file).replace("\\", "/")
    _session_start()

    return {
        "project_file": str(file).replace("\\", "/"),
        "collaboration": model,
        "project_file_changed": changed,
        "sidecars_found": len(sidecars),
        "sidecars_updated": len(updated),
        "updated": updated,
    }
