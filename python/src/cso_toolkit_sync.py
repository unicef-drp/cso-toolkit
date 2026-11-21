"""Vintage-management helpers for the vendored copies of cso-toolkit code.

Python port of ``r/R/cso_toolkit_sync.R``.

Helpers in ``00_functions/`` are vendored copies of cso-toolkit code,
not installed via ``pip``.  This pins the vintage per consuming repo.
``.toolkit_manifest.yml`` records the upstream release tag the copies came
from (``pulled_version``, ``pulled_commit``) and the vendored files.

* :func:`cso_toolkit_check` — checks the vendored copy against a target
  version (offline) and, in producer mode, the latest upstream tag.
* :func:`cso_toolkit_diff` — compares each vendored file with the file at a
  release tag.
* :func:`cso_toolkit_pull` — refreshes the vendored files to a release tag
  and re-pins the manifest.
* :func:`cso_toolkit_sync` — the one call: latest tag, its NEWS, diff, pull.

Upstream files always come from a release tag, never a working tree: with
``toolkit_source`` (or ``CSO_TOOLKIT_ROOT``) from that local clone's git
history (``git cat-file``; the clone is never fetched or changed);
otherwise from a shallow clone of the tag over HTTPS from
``https://github.com/<source>.git`` (works where proxies block
api.github.com).  The git helpers here are also used by
``create_project.py``.
"""

from __future__ import annotations

import datetime as _dt
import difflib
import hashlib
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

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


# ---------------------------------------------------------------------------
# git and release-tag helpers (create_project.py uses them too)
# ---------------------------------------------------------------------------

def _cso_toolkit_source(toolkit_source: Optional[Union[str, Path]], fn: str,
                        checkout: bool = True,
                        alt: str = "or pass vendor=False and vendor by hand later") -> Path:
    """A local cso-toolkit clone: ``toolkit_source``, else ``CSO_TOOLKIT_ROOT``,
    else (``checkout=True``) the source checkout this file lives in."""
    src = str(toolkit_source) if toolkit_source else os.environ.get("CSO_TOOLKIT_ROOT", "")
    if not src and checkout:
        # A source checkout (pip install -e python/): this file is <clone>/python/src/.
        root = Path(__file__).resolve().parents[2]
        if (root / "r" / "R" / "dw_io.R").is_file():
            src = str(root)
    # A clone: the helpers are read from its git history (a release tag), so
    # the working tree only has to be a git repository of the toolkit.
    ok = bool(src) and (Path(src) / ".git").exists() \
        and (Path(src) / "r" / "DESCRIPTION").is_file()
    if not ok:
        where = f" ({src} is not a git clone of cso-toolkit)" if src else ""
        raise FileNotFoundError(
            f"[cso_toolkit.{fn}] No cso-toolkit clone to vendor the helpers from{where}.\n"
            "  Why: vendoring copies the helper files of a release tag from a git "
            "clone of the toolkit (git history, r/R/); the installed package does "
            "not carry them.\n"
            "  Fix: clone unicef-drp/cso-toolkit (with its tags) and pass "
            f"toolkit_source=\"<clone>\" (or set CSO_TOOLKIT_ROOT); {alt}."
        )
    if shutil.which("git") is None:
        raise RuntimeError(
            f"[cso_toolkit.{fn}] Vendoring reads the helpers from the clone's git "
            "history, but git is not on the PATH.\n"
            f"  Fix: install git, {alt}."
        )
    return Path(src).resolve()


def _cso_git_out(src: Union[str, Path], *args: str) -> Optional[List[str]]:
    """Run git in a clone; stdout lines, or None when git exits non-zero."""
    res = subprocess.run(["git", "-C", str(src), *args], capture_output=True)
    if res.returncode != 0:
        return None
    return res.stdout.decode("utf-8", "replace").splitlines()


def _cso_norm_tag(x: str) -> str:
    """A version written as a tag: ``0.9.1`` -> ``v0.9.1``; others unchanged."""
    return "v" + x if x[:1].isdigit() else x


def _cso_resolve_tag(src: Path, toolkit_version: Optional[str], fn: str,
                     arg: str = "toolkit_version") -> Dict[str, str]:
    """The release tag to vendor and the commit it points to.

    ``None`` takes the clone's latest release tag (``v`` and dot-separated
    numbers; pre-release tags are passed over). A version without the
    leading ``v`` gets one.
    """
    if toolkit_version is None:
        tags = [t for t in (_cso_git_out(src, "tag", "--list", "v*", "--sort=-v:refname") or [])
                if re.fullmatch(r"v[0-9]+(\.[0-9]+)*", t)]
        if not tags:
            raise LookupError(
                f"[cso_toolkit.{fn}] The clone at {src} has no release tag "
                "(v<major>.<minor>.<patch>).\n"
                "  Why: vendored helpers come from a release tag, never from a working "
                "tree, so the manifest names a real release.\n"
                f"  Fix: fetch the tags (git -C \"{src}\" fetch --tags), or pass "
                f"{arg}=\"vX.Y.Z\"."
            )
        tag = tags[0]
    else:
        if not isinstance(toolkit_version, str) or not toolkit_version:
            raise ValueError(
                f"[cso_toolkit.{fn}] `{arg}` must be one tag name, e.g. "
                "\"v0.9.1\".\n  Fix: pass a release tag of the clone, or None for its latest."
            )
        tag = _cso_norm_tag(toolkit_version)
    sha = _cso_git_out(src, "rev-list", "-n", "1", f"refs/tags/{tag}")
    if not sha or not re.fullmatch(r"[0-9a-f]{40}", sha[0]):
        have = _cso_git_out(src, "tag", "--list", "v*", "--sort=-v:refname") or []
        raise LookupError(
            f"[cso_toolkit.{fn}] Tag {tag} does not exist in the clone at {src}.\n"
            "  Why: vendored helpers come from a release tag, never from a working "
            "tree or a branch.\n"
            f"  Fix: pass one of the clone's tags (latest: "
            f"{', '.join(have[:5]) if have else 'none'}), or fetch the tags first "
            f"(git -C \"{src}\" fetch --tags)."
        )
    return {"tag": tag, "sha": sha[0]}


def _cso_git_blob(src: Union[str, Path], sha: str, path: str) -> Optional[bytes]:
    """Bytes of a file at a commit (git cat-file blob), or None if absent."""
    res = subprocess.run(["git", "-C", str(src), "cat-file", "blob", f"{sha}:{path}"],
                         capture_output=True)
    return res.stdout if res.returncode == 0 else None


def _cso_user() -> str:
    """The user name recorded as ``pulled_by``."""
    return os.environ.get("USERNAME") or os.environ.get("USER") or "unknown"


def _cso_latest_version_tag(tags) -> Optional[str]:
    """The highest release tag (``vX.Y.Z``, no pre-releases), compared numerically."""
    rel = {t for t in tags if re.fullmatch(r"v[0-9]+(\.[0-9]+)*", t)}
    if not rel:
        return None
    return max(rel, key=lambda t: tuple(int(p) for p in t[1:].split(".")))


def _cso_git_net(args: List[str], timeout: int = 300) -> subprocess.CompletedProcess:
    """Run a git command that reaches the network: no credential prompt, a
    timeout; returncode 124 on timeout."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(["git", *args], capture_output=True, timeout=timeout, env=env)
    except (subprocess.TimeoutExpired, OSError) as e:
        return subprocess.CompletedProcess(args, 124, b"", str(e).encode())


def _cso_remote_url(source_repo: str) -> str:
    """HTTPS URL of a GitHub ``owner/repo``."""
    return f"https://github.com/{source_repo}.git"


def _cso_ls_remote_latest(source_repo: str) -> Optional[str]:
    """Latest release tag via ``git ls-remote`` (no API), or None."""
    if shutil.which("git") is None:
        return None
    res = _cso_git_net(["ls-remote", "--tags", "--refs", _cso_remote_url(source_repo)], 60)
    if res.returncode != 0:
        return None
    tags = [ln.split("\trefs/tags/", 1)[1]
            for ln in res.stdout.decode("utf-8", "replace").splitlines()
            if "\trefs/tags/" in ln]
    return _cso_latest_version_tag(tags)


def _cso_upstream_latest_tag(source_repo: str) -> Optional[str]:
    """Look up the latest tag at the upstream repo.

    Tries ``gh api repos/<source>/releases/latest --jq .tag_name`` first;
    then ``requests.get('https://api.github.com/...')``; then
    ``git ls-remote --tags`` over HTTPS (the highest ``vX.Y.Z``), which works
    where proxies block api.github.com.  Returns ``None`` when all fail.
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
        requests = None
    if requests is not None:
        try:
            resp = requests.get(
                f"https://api.github.com/repos/{source_repo}/releases/latest",
                timeout=30,
            )
            if resp.status_code == 200 and resp.json().get("tag_name"):
                return resp.json().get("tag_name")
        except requests.RequestException:
            pass
    return _cso_ls_remote_latest(source_repo)


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


def _cso_version_cmp(a: tuple, b: tuple) -> int:
    """-1, 0, 1 for version tuples (shorter one padded with zeros)."""
    width = max(len(a), len(b))
    a = a + (0,) * (width - len(a))
    b = b + (0,) * (width - len(b))
    return (a > b) - (a < b)


def _cso_version_behind(pinned: Optional[str], target: Optional[str]) -> Optional[bool]:
    """``True`` when ``pinned`` is older than ``target`` (numeric compare),
    ``False`` when the same or newer, ``None`` when either is not a version.
    """
    p, t = _cso_version_norm(pinned), _cso_version_norm(target)
    if p is None or t is None:
        return None
    return _cso_version_cmp(p, t) < 0


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


_CSO_ALT_GITHUB = ("or leave toolkit_source unset (and CSO_TOOLKIT_ROOT empty) "
                   "to read the tag from GitHub")
_CSO_STATUSES = ["changed", "local_edit", "missing_local", "missing_upstream", "unchanged"]


def _cso_local_source(toolkit_source) -> Optional[str]:
    """``toolkit_source``, else ``CSO_TOOLKIT_ROOT``, else None (= GitHub)."""
    if toolkit_source:
        return str(toolkit_source)
    return os.environ.get("CSO_TOOLKIT_ROOT") or None


def _cso_upstream_path(f: str, fn: str) -> str:
    """Where a vendored file lives in the toolkit repository."""
    if re.search(r"\.[Rr]$", f):
        return f"r/R/{f}"
    if f.endswith(".py"):
        return f"python/src/{f}"
    raise ValueError(
        f"[cso_toolkit.{fn}] Cannot tell where the vendored file {f} lives in cso-toolkit.\n"
        "  Why: vendored files are mapped by extension: *.R to r/R/, *.py to python/src/.\n"
        f"  Fix: remove {f} from `vendored:` in .toolkit_manifest.yml (vendor it by "
        "hand), or fix the file name."
    )


def _cso_dbg(fn: str, debug: bool, msg: str) -> None:
    if debug:
        print(f"[cso_toolkit.{fn}:debug] {msg}")


def _cso_target_tag(m: dict, target_version: Optional[str], local: Optional[str], fn: str) -> str:
    """The release tag a call works on: the argument, or the latest."""
    if target_version is not None:
        if not isinstance(target_version, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", target_version):
            raise ValueError(
                f"[cso_toolkit.{fn}] `target_version` must be one tag name, e.g. \"v0.9.1\".\n"
                "  Fix: pass a release tag of cso-toolkit, or None for the latest."
            )
        return _cso_norm_tag(target_version)
    if local is not None:
        src = _cso_toolkit_source(local, fn, checkout=False, alt=_CSO_ALT_GITHUB)
        return _cso_resolve_tag(src, None, fn, arg="target_version")["tag"]
    tag = _cso_upstream_latest_tag(m["source"])
    if tag is None:
        raise ConnectionError(
            f"[cso_toolkit.{fn}] Could not find the latest release of {m['source']}.\n"
            "  Why: neither the gh CLI, the GitHub API nor `git ls-remote` over HTTPS "
            "reached GitHub.\n"
            "  Fix: check the network, or pass target_version=\"vX.Y.Z\", or "
            "toolkit_source=\"<a local cso-toolkit clone>\"."
        )
    return _cso_norm_tag(tag)


class _Tree:
    """The upstream files at a release tag: a git dir to read blobs from."""

    def __init__(self, dir: str, tag: str, sha: str, local: bool):
        self.dir, self.tag, self.sha, self.local = dir, tag, sha, local
        self.base_sha: Optional[str] = None

    def cleanup(self) -> None:
        if not self.local:
            shutil.rmtree(self.dir, ignore_errors=True)
            if os.path.exists(self.dir):  # read-only pack files on Windows
                def _rw(func, path, _exc):
                    os.chmod(path, 0o700)
                    func(path)
                shutil.rmtree(self.dir, onerror=_rw)


def _cso_upstream_tree(source_repo: str, tag: str, toolkit_source, fn: str,
                       base: Optional[str] = None, base_commit: Optional[str] = None,
                       debug: bool = False) -> _Tree:
    """A local clone's history as is (no fetch), or a shallow clone of the tag
    from GitHub into a temporary folder (call ``cleanup()``).  ``base``
    (``pulled_version``) is resolved too when possible; ``base_commit``
    (``pulled_commit``) is the fallback."""
    local = _cso_local_source(toolkit_source)
    if local is not None:
        src = _cso_toolkit_source(local, fn, checkout=False, alt=_CSO_ALT_GITHUB)
        rel = _cso_resolve_tag(src, tag, fn, arg="target_version")
        tree = _Tree(str(src), rel["tag"], rel["sha"], True)
        _cso_dbg(fn, debug, f"reading {rel['tag']} ({rel['sha']}) from the local clone {src}")
    else:
        if shutil.which("git") is None:
            raise RuntimeError(
                f"[cso_toolkit.{fn}] Reading a cso-toolkit release needs git, which is not "
                "on the PATH.\n  Fix: install git."
            )
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", source_repo or ""):
            raise ValueError(
                f"[cso_toolkit.{fn}] The manifest's `source:` ({source_repo or '<unset>'}) is "
                "not a GitHub owner/repo.\n"
                "  Fix: set `source: \"unicef-drp/cso-toolkit\"` in .toolkit_manifest.yml."
            )
        d = tempfile.mkdtemp(prefix="cso_upstream_")
        url = _cso_remote_url(source_repo)
        _cso_dbg(fn, debug, f"git clone --depth 1 --branch {tag} --no-checkout {url}")
        res = _cso_git_net(["clone", "--quiet", "--depth", "1", "--branch", tag,
                            "--no-checkout", url, d], 300)
        if res.returncode != 0:
            _Tree(d, tag, "", False).cleanup()
            err = " | ".join((res.stderr or b"").decode("utf-8", "replace").strip().splitlines()[-3:])
            raise ConnectionError(
                f"[cso_toolkit.{fn}] Could not read tag {tag} from {url}.\n"
                f"   git: {err}\n"
                "  Why: the tag does not exist there, or GitHub is not reachable over "
                "HTTPS from this machine.\n"
                "  Fix: check the tag name (cso_toolkit_check(quiet=False) shows the "
                "latest) and the network; or pass toolkit_source=\"<a local cso-toolkit "
                "clone>\" after `git -C <clone> fetch --tags`."
            )
        sha = (_cso_git_out(d, "rev-parse", "HEAD") or [""])[0]
        tree = _Tree(d, tag, sha, False)
        _cso_dbg(fn, debug, f"cloned {tag} ({sha}) into {d}")

    if base is not None and _cso_version_norm(base) is not None:
        btag = _cso_norm_tag(str(base))
        if btag == tree.tag:
            tree.base_sha = tree.sha
        else:
            if not tree.local:
                _cso_git_net(["-C", tree.dir, "fetch", "--quiet", "--depth", "1",
                              "origin", "tag", btag], 120)
            bsha = _cso_git_out(tree.dir, "rev-list", "-n", "1", f"refs/tags/{btag}")
            if bsha and re.fullmatch(r"[0-9a-f]{40}", bsha[0]):
                tree.base_sha = bsha[0]
    if tree.base_sha is None and isinstance(base_commit, str) \
            and re.fullmatch(r"[0-9a-f]{40}", base_commit):
        if _cso_git_out(tree.dir, "cat-file", "-t", base_commit) == ["commit"]:
            tree.base_sha = base_commit
    _cso_dbg(fn, debug, f"base (pulled_version {base}): "
             f"{tree.base_sha or 'not available; local edits cannot be told from upstream changes'}")
    return tree


def _cso_same(a: Optional[bytes], b: Optional[bytes]) -> bool:
    """Bytes equal, ignoring CRLF vs LF."""
    if a == b:
        return True
    if a is None or b is None:
        return False
    return a.replace(b"\r\n", b"\n") == b.replace(b"\r\n", b"\n")


def _cso_sha256(x: Optional[bytes]) -> Optional[str]:
    return None if x is None else hashlib.sha256(x).hexdigest()


def _cso_diff_core(m: dict, mdir: Path, tree: _Tree, fn: str):
    """Compare every vendored file with the tag: (rows, target bytes)."""
    files = [str(f) for f in (m.get("vendored") or [])]
    up = [_cso_upstream_path(f, fn) for f in files]
    edits = [str(e) for e in (m.get("local_edits") or [])]
    edits = set(edits) | {os.path.basename(e) for e in edits}
    rows, target = [], {}
    for f, path in zip(files, up):
        lp = mdir / f
        loc = lp.read_bytes() if lp.is_file() else None
        tgt = _cso_git_blob(tree.dir, tree.sha, path)
        target[f] = tgt
        if tgt is None:
            status = "missing_upstream"
        elif loc is None:
            status = "missing_local"
        elif _cso_same(loc, tgt):
            status = "unchanged"
        elif f in edits:
            status = "local_edit"
        elif tree.base_sha is not None and not _cso_same(
                loc, _cso_git_blob(tree.dir, tree.base_sha, path)):
            # The vendored copy is not what pulled_version shipped: edited here.
            status = "local_edit"
        else:
            status = "changed"
        rows.append({"file": f, "status": status, "sha256_local": _cso_sha256(loc),
                     "sha256_target": _cso_sha256(tgt)})
    return rows, target


def _cso_frame(rows: List[dict], m: dict, tree: _Tree, action: bool = False):
    import pandas as pd
    cols = ["file", "status", "sha256_local", "sha256_target"] + (["action"] if action else [])
    df = pd.DataFrame(rows, columns=cols)
    df.attrs.update({"source": m.get("source"), "pulled_version": m.get("pulled_version"),
                     "target_version": tree.tag, "target_commit": tree.sha})
    return df


def _cso_diff_report(rows: List[dict], m: dict, tree: _Tree, mdir: Path, fn: str,
                     verbose: bool) -> None:
    if not verbose:
        return
    n = {s: sum(r["status"] == s for r in rows) for s in _CSO_STATUSES}
    head = (f"[cso_toolkit.{fn}] {m['source']} {tree.tag} ({tree.sha[:7]}) vs vendored "
            f"{_cso_tag(m.get('pulled_version') or '?')} in {mdir}: {n['changed']} changed, "
            f"{n['local_edit']} local edit(s), {n['missing_local']} missing locally, "
            f"{n['missing_upstream']} missing upstream, {n['unchanged']} unchanged")
    body = [f"   {r['status']:<17} {r['file']}" for r in rows if r["status"] != "unchanged"]
    print("\n".join([head] + body))


def _cso_show_diff(local: Optional[bytes], target: Optional[bytes], f: str, tag: str) -> None:
    a = (local or b"").decode("utf-8", "replace").splitlines(keepends=True)
    b = (target or b"").decode("utf-8", "replace").splitlines(keepends=True)
    print("".join(difflib.unified_diff(a, b, f"vendored/{f}", f"{tag}/{f}")))


def _cso_ask(prompt: str) -> str:
    """Prompt (separate so tests can replace it)."""
    return input(prompt)


def _cso_interactive() -> bool:
    """Interactive session? (separate so tests can replace it)."""
    return bool(sys.stdin) and sys.stdin.isatty()


def _cso_confirm_file(f: str, status: str, local, target, frm: str, to: str) -> bool:
    what = "is missing here" if status == "missing_local" else "changed upstream"
    for _ in range(10):
        a = _cso_ask(f"{f} {what} ({frm} -> {to}). [o]verwrite, [s]kip, show [d]iff? ").strip().lower()
        if a in ("o", "overwrite", "y", "yes"):
            return True
        if a in ("s", "skip", "n", "no"):
            return False
        if a in ("d", "diff"):
            _cso_show_diff(local, target, f, to)
    return False


def _cso_write_atomic(data: bytes, dest: Path) -> None:
    """A temporary file in the same folder, then a rename."""
    tmp = dest.parent / f".{dest.name}.cso_tmp"
    tmp.write_bytes(data)
    os.replace(tmp, dest)


def _cso_manifest_update(path: Path, tag: str, sha: str, date: str, user: str,
                         hashes: Dict[str, str]) -> None:
    """Re-pin the manifest by editing its lines in place (mirror of R
    ``.cso_manifest_update()``; the same bytes)."""
    s = path.read_bytes().decode("utf-8")
    eol = "\r\n" if "\r\n" in s else "\n"
    ends = s.endswith("\n")
    lines = re.split(r"\r?\n", s)
    if ends:
        lines = lines[:-1]

    def set_key(lines, key, value, after):
        new = f'{key}: "{value}"'
        for i, ln in enumerate(lines):
            if ln.startswith(f"{key}:"):
                rest = re.sub(rf"^{key}:[ \t]*", "", ln)
                cm = re.search(r"[ \t]+#.*$", rest)
                lines[i] = new + (cm.group(0) if cm else "")
                return lines, i
        at = after if after is not None else len(lines) - 1
        lines.insert(at + 1, new)
        return lines, at + 1

    src = next((i for i, ln in enumerate(lines) if ln.startswith("source:")), -1)
    lines, at = set_key(lines, "pulled_version", tag, src)
    lines, at = set_key(lines, "pulled_commit", sha, at)
    if any(ln.startswith("pulled_date:") for ln in lines):
        date_key = "pulled_date"
    elif any(ln.startswith("pulled_at:") for ln in lines):
        date_key = "pulled_at"
    else:
        date_key = "pulled_date"
    lines, at = set_key(lines, date_key, date, at)
    lines, at = set_key(lines, "pulled_by", user, at)

    fb = next((i for i, ln in enumerate(lines) if re.fullmatch(r"files:[ \t]*(#.*)?", ln)), None)
    if fb is not None and hashes:
        i = fb + 1
        while i < len(lines) and (re.match(r"[ \t]", lines[i]) or not lines[i].strip()):
            km = re.match(r"^[ \t]+([^:]+?)[ \t]*:", lines[i])
            h = hashes.get(km.group(1)) if km else None
            if h and re.search(r"[0-9a-f]{64}", lines[i]):
                lines[i] = re.sub(r'"?[0-9a-f]{64}"?', f'"{h}"', lines[i], count=1)
            i += 1
    out = eol.join(lines) + (eol if ends else "")
    _cso_write_atomic(out.encode("utf-8"), path)


def _cso_news_between(text: str, frm: Optional[str], to: str) -> Dict[str, List[str]]:
    """The NEWS.md sections after ``frm`` up to and including ``to``; lines
    under a Breaking/Changed ``###`` heading, or saying BREAKING, get ``!! ``.
    Mirror of R ``.cso_news_between()``."""
    lines = re.split(r"\r?\n", text)
    if text.endswith("\n"):
        lines = lines[:-1]
    h = [i for i, ln in enumerate(lines) if re.match(r"^##[ \t]+v?[0-9]", ln)]
    t, f = _cso_version_norm(to), _cso_version_norm(frm)
    out: List[str] = []
    flagged: List[str] = []
    for k, start in enumerate(h):
        raw = re.sub(r"^##[ \t]+(v?[0-9][^ \t(]*).*$", r"\1", lines[start])
        ver = _cso_version_norm(raw)
        if ver is None or t is None:
            continue
        vs = ".".join(str(p) for p in ver)
        keep = _cso_version_cmp(ver, t) <= 0 and (
            _cso_version_cmp(ver, t) == 0 if f is None else _cso_version_cmp(ver, f) > 0)
        if not keep:
            continue
        end = h[k + 1] if k + 1 < len(h) else len(lines)
        sec = lines[start:end]
        while sec and not sec[-1].strip():
            sec.pop()
        flag = False
        for j, ln in enumerate(sec):
            if re.match(r"^#{1,3}[ \t]", ln) and not ln.startswith("###"):
                flag = False
            elif ln.startswith("###"):
                flag = bool(re.search(r"breaking|changed", ln, re.IGNORECASE))
                if flag:
                    flagged.append(f"v{vs}: {ln}")
            hit = flag or "BREAKING" in ln
            if not flag and "BREAKING" in ln:
                flagged.append(f"v{vs}: {ln.strip()[:70]}")
            sec[j] = ("!! " if hit else "   ") + ln
        out += sec + [""]
    return {"lines": out, "flagged": flagged}


def _cso_dirty(d: Path) -> Optional[List[str]]:
    """None when ``d`` is not in a git work tree; else the porcelain lines."""
    if shutil.which("git") is None:
        return None
    if _cso_git_out(d, "rev-parse", "--is-inside-work-tree") != ["true"]:
        return None
    return _cso_git_out(d, "status", "--porcelain", "--", ".") or []


def _cso_require_manifest(fn: str) -> dict:
    m = _cso_load_manifest()
    if m is None:
        raise FileNotFoundError(
            f"[cso_toolkit.{fn}] No manifest; cannot refresh.\n"
            "  Why: the manifest names the upstream and the vendored files.\n"
            f"  Looked under: {_cso_manifest_path()}\n"
            "  Fix: create a .toolkit_manifest.yml next to the vendored "
            "helpers. See templates/.toolkit_manifest.yml in the toolkit "
            "repo for the schema."
        )
    if not m.get("source"):
        raise ValueError(
            f"[cso_toolkit.{fn}] Manifest has no `source:` key.\n"
            "  Why: the source names the repository to read the release from.\n"
            f"  Manifest path: {_cso_manifest_path()}\n"
            "  Fix: add `source: \"owner/repo\"` to the manifest."
        )
    return m


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
    * **The latest upstream tag** — producer mode only (gh CLI, the GitHub
      API, then ``git ls-remote --tags`` over HTTPS).  A newer tag is
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


def cso_toolkit_diff(target_version: Optional[str] = None, *,
                     toolkit_source: Optional[Union[str, Path]] = None,
                     verbose: bool = True, debug: bool = False):
    """Show per-file differences between the vendored copy and a release.

    Compares every file under ``vendored:`` in ``.toolkit_manifest.yml`` with
    the same file at a cso-toolkit release tag (``*.R`` from ``r/R/``,
    ``*.py`` from ``python/src/``) and prints a short summary.  Nothing is
    written.  Mirror of R ``cso_toolkit_diff()``.

    The tag is read from git history: from the local clone ``toolkit_source``
    (or ``CSO_TOOLKIT_ROOT``) without fetching or changing it; otherwise from
    a shallow clone of the tag from ``https://github.com/<source>.git`` into a
    temporary folder, deleted afterwards.

    Statuses: ``unchanged`` (line endings aside); ``changed`` (the pull
    updates it); ``local_edit`` (listed under ``local_edits:``, or differs
    from what ``pulled_version`` shipped; the pull skips it);
    ``missing_upstream`` (the pull keeps it and warns); ``missing_local``
    (the pull adds it).

    Reading from GitHub needs producer mode (``dw_apis_allowed``); with a
    local ``toolkit_source`` it runs in reviewer mode too (no network).

    Parameters
    ----------
    target_version
        Release tag (``"v0.10.0"``; ``"0.10.0"`` gets a ``v``).  ``None``:
        the latest release of the local clone, or of GitHub.
    toolkit_source
        A local git clone of cso-toolkit; ``None`` uses ``CSO_TOOLKIT_ROOT``,
        and GitHub when that is unset too.
    verbose, debug
        Print the summary / troubleshooting detail.

    Returns
    -------
    pandas.DataFrame or None
        Columns ``file``, ``status``, ``sha256_local``, ``sha256_target``;
        ``df.attrs`` holds ``source``, ``pulled_version``,
        ``target_version`` and ``target_commit``.  ``None`` without a
        manifest.
    """
    fn = "cso_toolkit_diff"
    m = _cso_load_manifest()
    if m is None:
        return None
    local = _cso_local_source(toolkit_source)
    if local is None and not _state._get("dw_apis_allowed"):
        raise PermissionError(
            f"[cso_toolkit.{fn}] Forbidden in reviewer mode without a local clone.\n"
            "  Why: reading a release from GitHub is a network call, which the "
            "reviewer-mode contract forbids.\n"
            "  Fix: pass toolkit_source=\"<a local cso-toolkit clone>\" (read offline), "
            "or switch to producer mode:\n"
            "    from cso_toolkit import _state\n"
            "    _state.configure(dw_mode=\"producer\", dw_apis_allowed=True)"
        )
    m = _cso_require_manifest(fn)
    mdir = _cso_manifest_path().parent
    tag = _cso_target_tag(m, target_version, local, fn)
    if verbose:
        print(f"[cso_toolkit.{fn}] comparing {mdir} with {m['source']} {tag}")
    tree = _cso_upstream_tree(m["source"], tag, local, fn, base=m.get("pulled_version"),
                              base_commit=m.get("pulled_commit"), debug=debug)
    try:
        rows, _ = _cso_diff_core(m, mdir, tree, fn)
        _cso_diff_report(rows, m, tree, mdir, fn, verbose or debug)
        return _cso_frame(rows, m, tree)
    finally:
        tree.cleanup()


def cso_toolkit_pull(target_version: Optional[str] = None, confirm: bool = True,
                     dry_run: bool = False, *,
                     toolkit_source: Optional[Union[str, Path]] = None,
                     allow_downgrade: bool = False,
                     verbose: bool = True, debug: bool = False):
    """Refresh the vendored copies to a cso-toolkit release.

    Mirror of R ``cso_toolkit_pull()``.  In order: refuses in reviewer mode,
    without a manifest or ``source:``; refuses when the vendored folder has
    uncommitted changes (``git status --porcelain``; an update must be one
    reviewable commit; ``dry_run`` skips this); refuses a downgrade unless
    ``allow_downgrade=True`` (the same tag reports "already at" and warns if
    the tag moved from ``pulled_commit``); compares as
    :func:`cso_toolkit_diff`; skips ``local_edit`` files, keeps
    ``missing_upstream`` ones (warning), writes ``changed`` and
    ``missing_local`` ones atomically; with ``confirm=True`` asks per file
    (overwrite / skip / show diff) and, in a non-interactive session, stops
    before writing; re-pins the manifest in place (``pulled_version``,
    ``pulled_commit``, ``pulled_date`` or ``pulled_at``, ``pulled_by``,
    hashes of an existing ``files:`` block; ``vendored``, ``local_edits``,
    ``target_version`` untouched).

    Returns
    -------
    pandas.DataFrame
        The diff frame with an ``action`` column: ``updated``, ``added``,
        ``skipped``, ``skipped_local_edit``, ``kept``, ``none``,
        ``would_update``, ``would_add``.
    """
    return _cso_pull_impl("cso_toolkit_pull", target_version, confirm, dry_run,
                          toolkit_source, allow_downgrade, verbose, debug, sync=False)


def cso_toolkit_sync(target_version: Optional[str] = None, confirm: bool = True,
                     dry_run: bool = False, *,
                     toolkit_source: Optional[Union[str, Path]] = None,
                     verbose: bool = True, debug: bool = False):
    """Update the vendored cso-toolkit in one call.

    Resolves the target (``target_version``, or the latest release); stops,
    saying so, when ``pulled_version`` is already there; prints the upstream
    ``NEWS.md`` sections (read from the target tag) for every version after
    ``pulled_version`` up to the target, marking with ``!!`` entries under
    Breaking or Changed headings; then compares and pulls as
    :func:`cso_toolkit_pull` does.  Mirror of R ``cso_toolkit_sync()``.

    Returns
    -------
    pandas.DataFrame or None
        ``None`` when up to date; otherwise the pull frame, with
        ``df.attrs["news"]`` (the printed release-note lines).
    """
    return _cso_pull_impl("cso_toolkit_sync", target_version, confirm, dry_run,
                          toolkit_source, False, verbose, debug, sync=True)


def _cso_pull_impl(fn: str, target_version, confirm, dry_run, toolkit_source,
                   allow_downgrade, verbose, debug, sync: bool):
    verbose = verbose or debug
    if not _state._get("dw_apis_allowed"):
        raise PermissionError(
            f"[cso_toolkit.{fn}] Forbidden in reviewer mode.\n"
            "  Why: an update changes the vendored helpers and re-pins the manifest, "
            "a producer's decision (and reading a release from GitHub is a network "
            "call, which reviewer mode forbids).\n"
            "  Fix: switch the profile to producer mode:\n"
            "    from cso_toolkit import _state\n"
            "    _state.configure(dw_mode=\"producer\", dw_apis_allowed=True)\n"
            "  To inspect only, use cso_toolkit_diff(toolkit_source=\"<a local clone>\")."
        )
    m = _cso_require_manifest(fn)
    mpath = _cso_manifest_path()
    mdir = mpath.parent
    local = _cso_local_source(toolkit_source)
    if not sync and target_version is None:
        raise ValueError(
            f"[cso_toolkit.{fn}] `target_version` is required.\n"
            "  Why: a pull names the release it moves to.\n"
            "  Fix: pass a tag, e.g. cso_toolkit_pull(\"v0.10.0\"), or run "
            "cso_toolkit_sync() to update to the latest release."
        )
    tag = _cso_target_tag(m, target_version, local, fn)
    pinned = m.get("pulled_version")
    pinned_s = str(pinned) if pinned is not None else None
    same = pinned_s is not None and _cso_norm_tag(pinned_s) == tag
    _cso_dbg(fn, debug, f"manifest {mpath} | pulled_version={pinned} | target={tag} | "
             f"source={local or 'GitHub ' + m['source']} | confirm={confirm} | dry_run={dry_run}")

    if sync and (same or (_cso_version_behind(pinned_s, tag) is False and target_version is None)):
        if verbose:
            print(f"[cso_toolkit.{fn}] up to date: vendored {_cso_tag(pinned_s)}, "
                  f"{'latest release' if target_version is None else 'target'} {tag}")
        return None
    if _cso_version_behind(tag, pinned_s) and not allow_downgrade:
        raise ValueError(
            f"[cso_toolkit.{fn}] {tag} is older than the vendored {_cso_tag(pinned_s)} "
            "(pulled_version).\n"
            "  Why: moving back to an older release is a downgrade, which is refused "
            "unless asked for.\n"
            f"  Fix: pass a tag at or after {_cso_tag(pinned_s)}, or "
            f"cso_toolkit_pull(\"{tag}\", allow_downgrade=True) if you mean to go back."
        )
    if not dry_run:
        dirty = _cso_dirty(mdir)
        if dirty:
            raise RuntimeError(
                f"[cso_toolkit.{fn}] {mdir} has uncommitted changes:\n   "
                + "\n   ".join(dirty[:10]) + "\n"
                "  Why: an update must be one reviewable commit, so it starts from a "
                "clean folder.\n"
                "  Fix: commit or stash those changes first, then run it again (or use "
                "dry_run=True to look)."
            )
        if dirty is None:
            _cso_dbg(fn, debug, f"{mdir} is not in a git repository: no uncommitted-change check")

    tree = _cso_upstream_tree(m["source"], tag, local, fn, base=pinned_s,
                              base_commit=m.get("pulled_commit"), debug=debug)
    try:
        news: List[str] = []
        if sync:
            nb = _cso_git_blob(tree.dir, tree.sha, "NEWS.md")
            if nb is None:
                if verbose:
                    print(f"[cso_toolkit.{fn}] no NEWS.md at {tag}")
            else:
                nw = _cso_news_between(nb.decode("utf-8", "replace"), pinned_s, tag)
                news = nw["lines"]
                if verbose:
                    head = (f"[cso_toolkit.{fn}] release notes {_cso_tag(pinned_s)} -> {tag} "
                            f"(NEWS.md at {tag}; !! = Breaking or Changed: read before updating)")
                    tail = (["flagged:"] + [f"   {x}" for x in nw["flagged"]]
                            if nw["flagged"] else ["flagged: none"])
                    print("\n".join([head, ""] + news + tail))

        rows, target = _cso_diff_core(m, mdir, tree, fn)
        _cso_diff_report(rows, m, tree, mdir, fn, verbose)
        for r in rows:
            r["action"] = {"local_edit": "skipped_local_edit",
                           "missing_upstream": "kept"}.get(r["status"], "none")

        if same:
            pc = m.get("pulled_commit")
            if pc and pc != tree.sha:
                warnings.warn(
                    f"[cso_toolkit.{fn}] Tag {tag} now points to {tree.sha[:7]}, but the "
                    f"manifest records pulled_commit {str(pc)[:7]}.\n"
                    "  Why: the tag was moved or re-created upstream after this repository "
                    "vendored it.\n"
                    f"  Fix: compare with cso_toolkit_diff(target_version=\"{tag}\") and ask "
                    "the toolkit maintainers which commit is the release.",
                    stacklevel=3,
                )
            if verbose:
                print(f"[cso_toolkit.{fn}] already at {tag}: nothing written")
            return _cso_frame(rows, m, tree, action=True)

        todo = [r for r in rows if r["status"] in ("changed", "missing_local")]
        if todo and not dry_run and confirm and not _cso_interactive():
            raise RuntimeError(
                f"[cso_toolkit.{fn}] confirm=True needs an interactive session to ask per "
                "file, and this one is not.\n"
                f"  Why: {len(todo)} file(s) would be overwritten without anyone choosing.\n"
                "  Fix: run it again with confirm=False (after cso_toolkit_diff() or "
                "dry_run=True), or run it in an interactive Python session."
            )
        for r in todo:
            f, add = r["file"], r["status"] == "missing_local"
            if dry_run:
                r["action"] = "would_add" if add else "would_update"
                continue
            lp = mdir / f
            if confirm and not _cso_confirm_file(
                    f, r["status"], lp.read_bytes() if lp.is_file() else None,
                    target[f], _cso_tag(pinned_s), tag):
                r["action"] = "skipped"
                continue
            _cso_write_atomic(target[f], lp)
            r["action"] = "added" if add else "updated"

        kept = [r["file"] for r in rows if r["status"] == "missing_upstream"]
        if kept:
            warnings.warn(
                f"[cso_toolkit.{fn}] Not in cso-toolkit {tag}, kept as vendored: "
                f"{', '.join(kept)}\n"
                "  Why: the release no longer has these files (removed or renamed "
                "upstream).\n"
                f"  Fix: read NEWS.md for {tag}; delete them and their `vendored:` "
                "entries if nothing uses them.",
                stacklevel=3,
            )
        declined = [r["file"] for r in rows if r["action"] == "skipped"]

        if not dry_run:
            hashes = {r["file"]: _cso_sha256((mdir / r["file"]).read_bytes())
                      for r in rows if (mdir / r["file"]).is_file()}
            _cso_manifest_update(mpath, tag, tree.sha, _dt.date.today().isoformat(),
                                 _cso_user(), hashes)

        if verbose:
            def lst(*acts):
                fs = [r["file"] for r in rows if r["action"] in acts]
                return f"{len(fs)}" + (f" ({', '.join(fs)})" if fs else "")
            frm = _cso_tag(pinned_s)
            if dry_run:
                print(f"[cso_toolkit.{fn}] dry run {frm} -> {tag}: would update "
                      f"{lst('would_update')}, would add {lst('would_add')}; skip "
                      f"{lst('skipped_local_edit')} local edit(s); keep {lst('kept')} "
                      "missing upstream. Nothing written.")
            else:
                print(f"[cso_toolkit.{fn}] {frm} -> {tag} ({tree.sha[:7]}): updated "
                      f"{lst('updated')}, added {lst('added')}; skipped "
                      f"{lst('skipped_local_edit')} local edit(s)"
                      + (f", declined {lst('skipped')}" if declined else "")
                      + f"; kept {lst('kept')} missing upstream; manifest re-pinned.")
                if declined:
                    print(f"[cso_toolkit.{fn}] declined files now differ from {tag}: list "
                          "them under local_edits: in the manifest, or pull again.")
                print(f"[cso_toolkit.{fn}] next: read NEWS, run tools/check.R and the tests, "
                      f"commit {mdir.name}/ in one commit naming old and new tags "
                      f"(\"Update cso-toolkit {frm} -> {tag}\").")
        df = _cso_frame(rows, m, tree, action=True)
        if sync:
            df.attrs["news"] = news
        return df
    finally:
        tree.cleanup()
