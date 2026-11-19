"""Vintage-management helpers for the vendored copies of cso-toolkit code.

Python port of ``r/R/cso_toolkit_sync.R``.

Helpers in ``00_functions/`` are vendored copies of cso-toolkit code,
not installed via ``pip``.  This pins the vintage per consuming repo.
``.toolkit_manifest.yml`` records the upstream version + per-file
hashes at pull time.

* :func:`cso_toolkit_check` — quietly checks if upstream has a newer tag
  (producer mode only; respects ``_state.dw_apis_allowed``).
* :func:`cso_toolkit_diff` — shows what changed in upstream vs vendored
  copy (stub).
* :func:`cso_toolkit_pull` — refreshes the vendored files to a target
  tag (stub).
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import warnings
from pathlib import Path
from typing import Any, Optional

from . import _state

_log = logging.getLogger(__name__)


def _cso_manifest_path() -> Path:
    """Locate the toolkit manifest next to vendored helpers."""
    root_str = _state._get("dwFunct") or os.path.join(os.getcwd(), "00_functions")
    return Path(root_str) / ".toolkit_manifest.yml"


def _cso_load_manifest() -> Optional[dict]:
    """Read the toolkit manifest into a dict.  Returns ``None`` on
    missing file or missing PyYAML."""
    try:
        import yaml
    except ImportError:
        _log.warning("cso_toolkit_sync: PyYAML not installed; skipping checks")
        return None
    mpath = _cso_manifest_path()
    if not mpath.exists():
        _log.info(
            "cso_toolkit_sync: no manifest at %s — helpers are not "
            "vendored from any upstream.", mpath,
        )
        return None
    with open(mpath, encoding="utf-8") as f:
        return yaml.safe_load(f)


def _cso_upstream_latest_tag(source_repo: str) -> Optional[str]:
    """Look up the latest tag at the upstream repo.

    Tries ``gh api repos/<source>/releases/latest --jq .tag_name`` first;
    falls back to ``requests.get('https://api.github.com/...')`` when
    ``gh`` is missing.  Returns ``None`` when both paths fail.
    """
    if shutil.which("gh"):
        try:
            out = subprocess.check_output(
                ["gh", "api", f"repos/{source_repo}/releases/latest",
                 "--jq", ".tag_name"],
                stderr=subprocess.DEVNULL, timeout=30,
            ).decode("utf-8").strip()
            if out:
                return out
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
            pass

    try:
        import requests
    except ImportError:
        return None
    try:
        resp = requests.get(
            f"https://api.github.com/repos/{source_repo}/releases/latest",
            timeout=30,
        )
        if resp.status_code == 200:
            return resp.json().get("tag_name")
    except requests.RequestException:
        return None
    return None


def _cso_version_norm(x: Optional[str]) -> Optional[tuple]:
    """Normalise a toolkit tag to a tuple of ints for comparison.

    Strips a leading ``v`` and any pre-release / build suffix (``-rc1``,
    ``+meta``).  Returns ``None`` for anything that is not a dotted version
    number (e.g. ``"inrepo"``).  Mirror of R ``.cso_version_norm()``.
    """
    if x is None:
        return None
    s = str(x).strip()
    if s.startswith("v"):
        s = s[1:]
    s = re.split(r"[-+]", s, maxsplit=1)[0]
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", s):
        return None
    return tuple(int(p) for p in s.split("."))


def _cso_version_behind(pinned: Optional[str], target: Optional[str]) -> Optional[bool]:
    """``True`` when ``pinned`` is older than ``target`` (numeric compare),
    ``False`` when the same or newer, ``None`` when either is not a version.
    """
    p, t = _cso_version_norm(pinned), _cso_version_norm(target)
    if p is None or t is None:
        return None
    width = max(len(p), len(t))
    return p + (0,) * (width - len(p)) < t + (0,) * (width - len(t))


def _cso_tag(x: str) -> str:
    """Format a tag with a single leading ``v``."""
    s = str(x)
    return "v" + (s[1:] if s.startswith("v") else s)


def _cso_box(lines: list) -> str:
    """Draw an ASCII box (renders the same in every console)."""
    lines = [ln for ln in lines if ln is not None]
    w = max(len(ln) for ln in lines) + 2
    bar = "+" + "-" * w + "+"
    return "\n".join([bar] + [f"| {ln.ljust(w - 2)} |" for ln in lines] + [bar])


def cso_toolkit_check(quiet: bool = True,
                      target_version: Optional[str] = None) -> Optional[dict]:
    """Check whether the vendored toolkit is behind a target or upstream.

    Compares the manifest's ``pulled_version`` with two references:

    * **A target version** — the ``target_version`` argument, or else the
      manifest's optional ``target_version:`` key.  The comparison is
      offline, so it runs in **both** producer and reviewer mode.  When the
      vendored copy is behind the target the check is loud: it emits a
      ``[cso_toolkit.cso_toolkit_check]`` warning carrying the exact
      ``cso_toolkit_pull(target_version=...)`` command and, with
      ``quiet=False``, logs a boxed alert at WARNING level.  Reviewer mode
      only warns: it never polls GitHub or changes any file.
    * **The latest upstream tag** — producer mode only.  A newer tag is
      informational: with ``quiet=False`` it logs a boxed notice, but does
      not warn.

    Versions compare numerically (``0.10.0`` is newer than ``0.9.1``); a
    ``pulled_version`` of ``"inrepo"`` is never reported as behind.

    Returns ``None`` when the manifest is missing, and in reviewer mode when
    no target version is set.  Mirror of R ``cso_toolkit_check()``.

    Parameters
    ----------
    quiet
        If ``True`` (default), log nothing.  Being behind a target version
        still emits a warning, so a required re-vendor is never silent.
    target_version
        Tag the vendored copy must be at or above (e.g. ``"v0.9.1"``).
        Overrides the manifest's ``target_version:`` key.

    Returns
    -------
    dict or None
        Keys: ``source``, ``pinned_version``, ``upstream_version``,
        ``updates_available``, ``target_version``, ``target_source``,
        ``behind_target``, ``updated_files``.
    """
    reviewer = not _state._get("dw_apis_allowed")
    m = _cso_load_manifest()
    if m is None:
        return None

    pinned = m.get("pulled_version") or "0.0.0"
    target = target_version if target_version is not None else m.get("target_version")
    target_source = ("argument" if target_version is not None
                     else "manifest" if m.get("target_version") is not None else None)
    behind_target = _cso_version_behind(pinned, target) if target is not None else None

    res = {
        "source": m.get("source"),
        "pinned_version": pinned,
        "upstream_version": None,
        "updates_available": None,
        "target_version": target,
        "target_source": target_source,
        "behind_target": behind_target,
        "updated_files": None,
    }

    # --- Upstream poll (producer mode only) ---------------------------------
    source = m.get("source")
    if reviewer:
        if not quiet:
            _log.info("cso_toolkit_check: upstream poll skipped (reviewer mode forbids API calls)")
    elif not source:
        if not quiet:
            _log.info("cso_toolkit_check: manifest has no upstream source")
    else:
        upstream = _cso_upstream_latest_tag(source)
        if upstream is None:
            if not quiet:
                _log.info("cso_toolkit_check: upstream %r not reachable or has no tags.", source)
        else:
            res["upstream_version"] = upstream
            res["updates_available"] = bool(_cso_version_behind(pinned, upstream))

    # --- Target: loud when behind (both modes; offline) ---------------------
    if behind_target:
        tag = _cso_tag(target)
        where = ("target_version argument" if target_source == "argument"
                 else "manifest target_version")
        if not quiet:
            _log.warning("\n" + _cso_box([
                "cso-toolkit is BEHIND its target version",
                f"  vendored : {_cso_tag(pinned)}",
                f"  target   : {tag}  ({where})",
                (f"  latest   : {_cso_tag(res['upstream_version'])}  (upstream)"
                 if res["upstream_version"] else None),
                "",
                ("Producer mode is needed to update (reviewer mode only warns):"
                 if reviewer else "To update:"),
                f'  cso_toolkit_diff(target_version="{tag}")',
                f'  cso_toolkit_pull(target_version="{tag}")',
            ]))
        warnings.warn(
            f"[cso_toolkit.cso_toolkit_check] The vendored cso-toolkit "
            f"({_cso_tag(pinned)}) is behind its target version {tag} (from the "
            f"{'target_version argument' if target_source == 'argument' else 'manifest target_version key'}).\n "
            + ("Reviewer mode: no network call was made and nothing was changed; "
               "ask the producer to re-vendor." if reviewer else
               "Pipelines run on the older helpers until the re-vendor.")
            + f'\n Fix: in producer mode, run cso_toolkit_pull(target_version="{tag}") '
            f"(or re-vendor {tag} by hand) and update pulled_version in "
            ".toolkit_manifest.yml.",
            stacklevel=2,
        )
    elif res["updates_available"] and not quiet:
        tag = _cso_tag(res["upstream_version"])
        _log.warning("\n" + _cso_box([
            "A newer cso-toolkit release is available",
            f"  vendored : {_cso_tag(pinned)}",
            f"  latest   : {tag}  ({source})",
            "",
            "To see the changes and update:",
            f'  cso_toolkit_diff(target_version="{tag}")',
            f'  cso_toolkit_pull(target_version="{tag}")',
        ]))
    elif not quiet and res["upstream_version"]:
        _log.info("[cso-toolkit] %s: vendored %s, latest upstream %s (up to date)",
                  source, _cso_tag(pinned), _cso_tag(res["upstream_version"]))

    # Reviewer mode with no target, or producer mode with neither upstream nor
    # target: nothing could be checked (as before).
    if target is None and (reviewer or res["upstream_version"] is None):
        return None
    return res


def cso_toolkit_diff(target_version: Optional[str] = None) -> None:
    """Show per-file diff between vendored copy and upstream version.

    Stub for v0.0.0.  The implementation will fetch upstream files at
    the target tag and compare via sha256 + a textual diff if requested.

    Parameters
    ----------
    target_version
        Optional explicit tag to diff against.
    """
    m = _cso_load_manifest()
    if m is None:
        return None
    _log.info(
        "cso_toolkit_diff: not yet implemented. "
        "Upstream repo (%s) needs to exist before diff is meaningful. "
        "Once it does, this will fetch each file at the target tag and "
        "compare sha256 against the vendored copy.",
        m.get("source") or "<unset>",
    )
    return None


def cso_toolkit_pull(target_version: str, confirm: bool = True,
                     dry_run: bool = False) -> None:
    """Refresh the vendored copies to a specific cso-toolkit tag.

    Stub for v0.0.0.  Planned behaviour:

    1. Read ``.toolkit_manifest.yml``.
    2. For each file in ``m['vendored']``: fetch it from ``m['source']``
       at ``target_version``; compute sha256 against the current vendored
       copy; if different, prompt the user (overwrite / skip / show diff).
    3. Update the manifest with the new version + hashes.
    4. Log a summary.

    Parameters
    ----------
    target_version
        Tag to pull (e.g. ``"v0.2.0"``).
    confirm
        Prompt per file.
    dry_run
        Show what would change without writing.
    """
    if not _state._get("dw_apis_allowed"):
        raise PermissionError(
            "[cso_toolkit.cso_toolkit_pull] Forbidden in reviewer mode.\n"
            "  Reason: pulling a new toolkit version requires hitting "
            "GitHub, which the reviewer-mode contract forbids.\n"
            "  Fix: switch the profile to producer mode:\n"
            "    from cso_toolkit import _state\n"
            "    _state.configure(dw_mode=\"producer\", dw_apis_allowed=True)"
        )
    m = _cso_load_manifest()
    if m is None:
        raise FileNotFoundError(
            "[cso_toolkit.cso_toolkit_pull] No manifest; cannot refresh.\n"
            f"  Looked under: {_cso_manifest_path()}\n"
            "  Fix: create a .toolkit_manifest.yml next to the vendored "
            "helpers. See templates/.toolkit_manifest.yml in the toolkit "
            "repo for the schema."
        )
    source = m.get("source")
    if not source:
        raise ValueError(
            "[cso_toolkit.cso_toolkit_pull] Manifest has no `source:` key.\n"
            f"  Manifest path: {_cso_manifest_path()}\n"
            "  Fix: add `source: \"owner/repo\"` to the manifest."
        )

    if _cso_upstream_latest_tag(source) is None:
        raise ConnectionError(
            f"[cso_toolkit.cso_toolkit_pull] Upstream {source!r} not "
            "reachable or has no tags.\n"
            "  Possible causes:\n"
            "    - The repo doesn't exist yet.\n"
            "    - The network is blocked (UNICEF corporate proxies "
            "sometimes block api.github.com).\n"
            "    - Neither `gh` CLI nor `requests` is installed.\n"
            "  Fix: verify the repo exists, then `gh auth status` or "
            "`pip install requests`."
        )

    _log.info(
        "cso_toolkit_pull: implementation TBD. "
        "Target version=%s, dry_run=%s. "
        "This will fetch files, prompt per-file overwrite, update manifest.",
        target_version, dry_run,
    )
    return None
