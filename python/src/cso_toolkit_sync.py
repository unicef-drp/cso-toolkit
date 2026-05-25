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
import shutil
import subprocess
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


def cso_toolkit_check(quiet: bool = True) -> Optional[dict]:
    """Check if a newer cso-toolkit version is available upstream.

    Quiet by default: returns a dict describing the state and prints
    nothing.  Pass ``quiet=False`` to log the result.

    Returns ``None`` when any of the following apply:

    * Manifest is missing.
    * Upstream repo does not exist (e.g., the toolkit has not been
      created yet).
    * Network is unavailable.
    * We're in reviewer mode (the mode contract forbids API calls).

    Parameters
    ----------
    quiet
        If ``True`` (default), suppress all log output.

    Returns
    -------
    dict or None
        Keys: ``source``, ``pinned_version``, ``upstream_version``,
        ``updates_available``, ``updated_files``.
    """
    if not _state._get("dw_apis_allowed"):
        if not quiet:
            _log.info("cso_toolkit_check: skipped (reviewer mode forbids API calls)")
        return None

    m = _cso_load_manifest()
    if m is None:
        return None

    source = m.get("source")
    if not source:
        if not quiet:
            _log.info("cso_toolkit_check: manifest has no upstream source")
        return None

    upstream = _cso_upstream_latest_tag(source)
    if upstream is None:
        if not quiet:
            _log.info(
                "cso_toolkit_check: upstream %r not reachable or has no tags.",
                source,
            )
        return None

    pinned = m.get("pulled_version") or "0.0.0"
    pinned_norm = pinned[1:] if pinned.startswith("v") else pinned
    upstream_norm = upstream[1:] if upstream.startswith("v") else upstream
    updates_available = (pinned_norm != upstream_norm) and ("inrepo" not in pinned)

    res = {
        "source": source,
        "pinned_version": pinned,
        "upstream_version": upstream,
        "updates_available": updates_available,
        "updated_files": None,
    }

    if not quiet:
        if updates_available:
            _log.info(
                "[cso-toolkit] %s: pinned v%s -> upstream %s (newer tag available)",
                source, pinned, upstream,
            )
            _log.info("              Run cso_toolkit_diff() to see what changed.")
            _log.info("              Run cso_toolkit_pull(%r) to refresh.", upstream)
        else:
            _log.info(
                "[cso-toolkit] %s: pinned %s == upstream %s (up to date)",
                source, pinned, upstream,
            )

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
