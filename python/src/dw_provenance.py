"""dw_provenance -- read provenance sidecars and compare two runs.

Python port of ``r/R/dw_provenance.R`` (#152). :func:`dw_save` writes a
``<path>.provenance.json`` sidecar beside every output: the output's SHA-256,
schema, unique key, user, mode and a caller-supplied ``metadata`` block. When
that block carries an ``inputs`` record (file + SHA-256 per input, e.g. the
manifest returned by :func:`dw_fetch_inputs`), the sidecar ties the output to
the exact inputs it was built from.

* :func:`dw_read_provenance` reads the sidecar of an output;
* :func:`dw_provenance_diff` compares the sidecars of two runs of the same
  output: reproduced, inputs changed, output changed, first run, or no input
  record.

Record-level differences are :func:`dw_compare`'s job. Read-only; behaves
identically in producer and reviewer sessions.
"""
from __future__ import annotations

import json
import os
import warnings
from typing import Any, Dict, Optional, Union

import pandas as pd

__all__ = ["dw_read_provenance", "dw_provenance_diff"]


def _say(fn: str, verbose: Optional[bool], msg: str) -> None:
    if verbose is None or verbose:
        print(f"[cso_toolkit.{fn}] {msg}")


def _records_to_frames(x: Any) -> Any:
    """JSON arrays of records become DataFrames, as R's simplifyVector does."""
    if isinstance(x, dict):
        return {k: _records_to_frames(v) for k, v in x.items()}
    if isinstance(x, list) and x and all(isinstance(r, dict) for r in x):
        return pd.DataFrame(x)
    return x


def dw_read_provenance(path: Union[str, os.PathLike], verbose: Optional[bool] = None,
                       debug: Optional[bool] = None) -> Optional[Dict[str, Any]]:
    """Read the provenance sidecar of an output.

    ``path`` may be the output itself or its ``.provenance.json`` sidecar.
    Mirror of R ``dw_read_provenance()``.

    Returns
    -------
    dict or None
        The parsed sidecar (``path``, ``format``, ``written_at``, ``user``,
        ``dw_mode``, ``vintage``, ``sha256``, ``isid``, ``schema``,
        ``metadata``), with arrays of records as DataFrames (so
        ``metadata["inputs"]`` is a DataFrame). ``None`` when there is no
        sidecar.

    Raises
    ------
    ValueError
        The sidecar exists but is not valid JSON.
    """
    path = str(path)
    sidecar = path if path.endswith(".provenance.json") else path + ".provenance.json"
    if debug:
        _say("dw_read_provenance", True, f"sidecar={sidecar}")
    if not os.path.exists(sidecar):
        _say("dw_read_provenance", verbose, f"no provenance sidecar for {os.path.basename(path)}")
        return None
    try:
        with open(sidecar, encoding="utf-8") as fh:
            prov = json.load(fh)
    except ValueError as e:
        raise ValueError(
            f"[cso_toolkit.dw_read_provenance] The provenance sidecar is not valid JSON: {sidecar}\n"
            f"  Parser said: {e}\n"
            "  Fix: rewrite the output with dw_save() to regenerate its sidecar, or restore the "
            "sidecar from version control."
        ) from None
    return _records_to_frames(prov)


def _as_provenance(x: Any, verbose, debug) -> Optional[Dict[str, Any]]:
    if x is None:
        return None
    if isinstance(x, dict):
        return x
    if isinstance(x, (str, os.PathLike)):
        return dw_read_provenance(x, verbose=verbose, debug=debug)
    raise TypeError(
        "[cso_toolkit.dw_provenance_diff] `previous` and `current` must be a path, a parsed "
        "sidecar (dict), or None.\n  Fix: pass the output path or the result of "
        "dw_read_provenance()."
    )


def _inputs(prov: Dict[str, Any], key: str) -> Optional[pd.DataFrame]:
    rec = (prov.get("metadata") or {}).get(key)
    if rec is None:
        return None
    if isinstance(rec, list):
        rec = pd.DataFrame(rec)
    if not isinstance(rec, pd.DataFrame) or not {"file", "sha256"} <= set(rec.columns):
        return None
    return rec[["file", "sha256"]]


def dw_provenance_diff(previous: Any, current: Any, inputs_key: str = "inputs",
                       warn: bool = True, verbose: Optional[bool] = None,
                       debug: Optional[bool] = None) -> Dict[str, Any]:
    """Compare the provenance of two runs of the same output.

    Answers, from the :func:`dw_save` sidecars alone, whether a new run
    reproduced the previous one. Inputs are compared through each sidecar's
    ``metadata[inputs_key]`` record (``file`` and ``sha256`` per input); the
    outputs through the sidecars' ``sha256``. Mirror of R
    ``dw_provenance_diff()``.

    ``status`` is one of ``reproduced`` (same inputs, byte-identical
    output), ``output_changed`` (same inputs, different output; warns with
    ``warn``), ``inputs_changed`` (lists returned), ``first_run`` (no
    previous sidecar) or ``no_input_record`` (only the outputs compared).

    Parameters
    ----------
    previous
        The previous output's path (or its sidecar), a parsed sidecar, or
        ``None``. Read it **before** the new run overwrites the output.
    current
        The new output's path (or its sidecar), or a parsed sidecar.

    Returns
    -------
    dict
        ``status``, ``same_inputs`` and ``same_output`` (``None`` when
        unknown), ``inputs_added``, ``inputs_removed``, ``inputs_changed``
        (lists of file names), ``previous_sha256``, ``current_sha256``.

    Raises
    ------
    FileNotFoundError
        The current output has no sidecar.
    """
    prev = _as_provenance(previous, verbose, debug)
    curr = _as_provenance(current, verbose, debug)
    if curr is None:
        raise FileNotFoundError(
            "[cso_toolkit.dw_provenance_diff] The current output has no provenance sidecar.\n"
            "  Fix: write the output with dw_save() (provenance=True, the default) before "
            "comparing runs."
        )
    out: Dict[str, Any] = {
        "status": None, "same_inputs": None, "same_output": None,
        "inputs_added": [], "inputs_removed": [], "inputs_changed": [],
        "previous_sha256": None if prev is None else prev.get("sha256"),
        "current_sha256": curr.get("sha256"),
    }
    if prev is None:
        out["status"] = "first_run"
        _say("dw_provenance_diff", verbose, "first run: no previous provenance to compare with")
        return out

    out["same_output"] = (out["current_sha256"] is not None
                          and out["previous_sha256"] == out["current_sha256"])
    pin, cin = _inputs(prev, inputs_key), _inputs(curr, inputs_key)
    if debug:
        _say("dw_provenance_diff", True, f"previous sha={out['previous_sha256']} | current "
             f"sha={out['current_sha256']} | inputs prev/curr="
             f"{0 if pin is None else len(pin)}/{0 if cin is None else len(cin)}")
    if pin is None or cin is None:
        out["status"] = "no_input_record"
        _say("dw_provenance_diff", verbose, f"a sidecar has no '{inputs_key}' record, so only the "
             "outputs were compared: " + ("byte-identical" if out["same_output"] else "different"))
        return out

    pmap = dict(zip(pin["file"], pin["sha256"]))
    cmap = dict(zip(cin["file"], cin["sha256"]))
    out["inputs_added"] = [f for f in cin["file"] if f not in pmap]
    out["inputs_removed"] = [f for f in pin["file"] if f not in cmap]
    out["inputs_changed"] = [f for f in cin["file"] if f in pmap and pmap[f] != cmap[f]]
    out["same_inputs"] = not (out["inputs_added"] or out["inputs_removed"] or out["inputs_changed"])

    if out["same_inputs"] and out["same_output"]:
        out["status"] = "reproduced"
        _say("dw_provenance_diff", verbose,
             "reproduced: same inputs (SHA-256) and a byte-identical output")
    elif out["same_inputs"]:
        out["status"] = "output_changed"
        if warn:
            warnings.warn(
                "[cso_toolkit.dw_provenance_diff] Same inputs as the previous run but a different "
                f"output (SHA-256 {str(out['previous_sha256'])[:12]} -> "
                f"{str(out['current_sha256'])[:12]}).\n"
                "  The code or the environment changed between the two runs.\n"
                "  Fix: if the change is intended, record it (commit, NEWS); otherwise run "
                "dw_compare() on the two outputs to find the records that moved.",
                UserWarning, stacklevel=2)
    else:
        out["status"] = "inputs_changed"
        parts = []
        for label, key in (("added", "inputs_added"), ("removed", "inputs_removed"),
                           ("changed", "inputs_changed")):
            if out[key]:
                parts.append(f"\n  {label + ':':<9}{', '.join(out[key])}")
        _say("dw_provenance_diff", verbose, "inputs changed since the previous run:" + "".join(parts))
    return out
