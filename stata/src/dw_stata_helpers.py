"""Python helpers for the Stata sibling (dw_save, dw_collaboration).

Stata has no SHA-256, no UTC clock, no JSON reader and no portable way to
run git, and AppLocker blocks external binaries on UNICEF laptops. Stata 16+
ships an embedded Python, so the .ado files call these functions through
`python:` and read the results back as Stata locals (sfi.Macro).

Each function mirrors the R/Python rule it is named after (r/R/dw_io.R):
the SHA-256 of the written file, an ISO-8601 UTC timestamp
(YYYY-MM-DDTHH:MM:SS+0000), and the multi-producer guards of #169/#178.
Stata-free functions (no sfi) so the module can be tested on its own.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import subprocess
from typing import Optional

ISO = "%Y-%m-%dT%H:%M:%S%z"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+0000")


def parse_iso(x) -> Optional[_dt.datetime]:
    if not isinstance(x, str) or not x:
        return None
    try:
        return _dt.datetime.strptime(x, ISO)
    except ValueError:
        return None


def current_user() -> str:
    """USERNAME, LOGNAME, USER, LNAME: R's .dw_current_user() order."""
    for var in ("USERNAME", "LOGNAME", "USER", "LNAME"):
        u = os.environ.get(var, "")
        if u:
            return u
    return ""


def read_sidecar(path: str) -> Optional[dict]:
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _str1(x) -> str:
    return x if isinstance(x, str) and x else ""


def _git(folder: str, *args: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["git", "-C", folder, *args], capture_output=True, text=True,
                              timeout=15)
    except (OSError, subprocess.SubprocessError):
        return subprocess.CompletedProcess(args, 127, "", "")


def git_info(path: str) -> tuple:
    """(branch, commit) of the folder holding path; '' when git is unavailable."""
    folder = os.path.dirname(os.path.abspath(path))
    out = []
    for args in (("rev-parse", "--abbrev-ref", "HEAD"), ("rev-parse", "HEAD")):
        r = _git(folder, *args)
        lines = r.stdout.strip().splitlines()
        out.append(lines[0] if r.returncode == 0 and len(lines) == 1 else "")
    return tuple(out)


def git_settled(path: str, sidecar: str) -> bool:
    """Both files tracked and identical to HEAD: the write arrived through git (#178)."""
    folder = os.path.dirname(os.path.abspath(path))
    files = [os.path.basename(path), os.path.basename(sidecar)]
    return (_git(folder, "ls-files", "--error-unmatch", "--", *files).returncode == 0
            and _git(folder, "diff", "--quiet", "HEAD", "--", *files).returncode == 0)


def preflight(path: str, me: str, session_start: str, reviewer: bool) -> dict:
    """The multi-producer guards for replacing `path` (R's .dw_collab_preflight).

    Returns fired (list of 'out_of_band' / 'concurrent'), why (text lines),
    note (text or ''), and the lineage fields for the new sidecar.
    """
    sidecar = path + ".provenance.json"
    file_sha = sha256_file(path) if os.path.exists(path) else ""
    prev = read_sidecar(sidecar) if os.path.exists(path) and os.path.exists(sidecar) else None
    prev_sha = _str1((prev or {}).get("sha256"))
    prev_user = _str1((prev or {}).get("user"))
    prev_at = _str1((prev or {}).get("written_at"))
    fired, why, note = [], [], ""
    if not reviewer and prev is not None:
        if prev_sha and file_sha and prev_sha != file_sha:
            fired.append("out_of_band")
            why.append(f"Why (out-of-band change): the file's SHA-256 ({file_sha[:12]}) no longer "
                       f"matches its provenance sidecar ({prev_sha[:12]}): someone changed it "
                       "without dw_save, so replacing it now would discard a change nobody recorded.")
        pa, sa = parse_iso(prev_at), parse_iso(session_start)
        later = bool(prev_user and prev_user != me and pa and sa and pa > sa)
        if later and not git_settled(path, sidecar):
            fired.append("concurrent")
            why.append(f"Why (concurrent write): {prev_user} wrote it at {prev_at}, after this "
                       f"session started ({session_start}); two producers writing the same output "
                       "in the same window would silently overwrite each other.")
        if not fired and prev_user and prev_user != me and "baseline" not in prev:
            note = (f"{os.path.basename(path)} was last written by {prev_user}"
                    + (f" at {prev_at}" if prev_at else "")
                    + "; your write follows theirs in its lineage.")
    branch, commit = git_info(path)
    return {"fired": fired, "why": why, "note": note,
            "previous_sha256": file_sha or prev_sha, "previous_user": prev_user,
            "previous_written_at": prev_at, "git_branch": branch, "git_commit": commit}


def json_str(x: str) -> str:
    """A JSON string literal (quotes included), for the .ado's file write."""
    return json.dumps(x, ensure_ascii=False)


def to_stata(prefix: str, result: dict) -> None:
    """Publish a preflight() result as Stata locals `prefix'<key>."""
    from sfi import Macro  # only inside Stata
    Macro.setLocal(prefix + "fired", " ".join(result["fired"]))
    Macro.setLocal(prefix + "nwhy", str(len(result["why"])))
    for i, w in enumerate(result["why"], start=1):
        Macro.setLocal(prefix + f"why{i}", w)
    Macro.setLocal(prefix + "note", result["note"])
    for k in ("previous_sha256", "previous_user", "previous_written_at", "git_branch", "git_commit"):
        Macro.setLocal(prefix + k, result[k])
