"""Redistribute survey weights from missing nested observations.

Python port of ``r/R/dw_nestweight.R``.  Computes a per-stratum
adjustment that scales original weights up so the sum of weights on
non-missing observations equals the sum of weights on all observations
in the stratum.  This is the textbook treatment for obtaining consistent
stratified aggregate estimates when missingness on the value of interest
is not completely at random within the stratum (MAR within strata, not
MCAR).

Within each level of ``by``:

.. math:: \\mathrm{scale}_l = \\frac{\\sum_{i \\in l} w_i}{\\sum_{i \\in l,\\ v_i\\ \\mathrm{observed}} w_i}

and the new weight is

.. math:: w'_i = w_i \\cdot \\mathrm{scale}_l \\quad \\mathrm{if}\\ v_i\\ \\mathrm{observed},\\quad 0 \\ \\mathrm{otherwise}.

This preserves the stratum total :math:`\\sum w'_i = \\sum w_i` while
concentrating mass on the observations that actually contribute to the
aggregate estimate of :math:`v`.

Ported from World Bank's ``EduAnalyticsToolkit::edukit_nestweight`` /
``nestweight`` v1.0 (8 Sep 2020), Author: Diana Goldemberg.  Algorithm
preserved; signature adapted to pandas conventions.
"""

from __future__ import annotations

import warnings
from typing import Optional

import numpy as np
import pandas as pd


def dw_nestweight(
    data: pd.DataFrame,
    value: str,
    by: str,
    weight: Optional[str] = None,
    new_weight: str = "weight_adj",
    only: Optional[pd.Series] = None,
    verbose: bool = True,
) -> pd.DataFrame:
    """Redistribute survey weights from missing nested observations.

    Parameters
    ----------
    data
        Input data frame.
    value
        Column name whose non-missingness drives the redistribution.
    by
        Column name defining the stratification (the level within which
        redistribution happens — typically a sampling stratum, country,
        or domain).
    weight
        Column name of the original weight.  If ``None`` (default), an
        implicit weight of 1 is used (so the helper degenerates to
        per-stratum non-missing counts).
    new_weight
        Name of the redistributed-weight column added to the returned
        data frame.
    only
        Boolean series of length ``len(data)`` restricting eligibility
        for the denominator.  Useful for "only redistribute over
        respondents who were asked the question".
    verbose
        Report per-stratum mean of ``value`` under original vs.
        redistributed weights, plus the pooled mean.

    Returns
    -------
    pd.DataFrame
        Input ``data`` with one new column (``new_weight``) appended.
    """
    if not isinstance(data, pd.DataFrame):
        raise TypeError(
            "[cso_toolkit.dw_nestweight] `data` must be a pandas DataFrame; "
            f"got {type(data).__name__!r}.\n"
            "  Fix: convert your input (e.g. `pd.DataFrame(data)`) before "
            "calling."
        )
    present = ", ".join(list(data.columns)[:10]) + (
        "..." if len(data.columns) > 10 else ""
    )
    if value not in data.columns:
        raise KeyError(
            f"[cso_toolkit.dw_nestweight] Column {value!r} (passed as "
            f"`value=`) not found in data.\n"
            f"  Data columns: {present}\n"
            "  Fix: check spelling / casing on the value column."
        )
    if by not in data.columns:
        raise KeyError(
            f"[cso_toolkit.dw_nestweight] Column {by!r} (passed as `by=`) "
            "not found in data.\n"
            f"  Data columns: {present}\n"
            "  Fix: check spelling / casing on the stratum column."
        )
    if weight is not None and weight not in data.columns:
        raise KeyError(
            f"[cso_toolkit.dw_nestweight] Column {weight!r} (passed as "
            "`weight=`) not found in data.\n"
            f"  Data columns: {present}\n"
            "  Fix: check spelling / casing, or pass weight=None to use "
            "implicit unit weights."
        )

    df = data.copy()
    v_obs = df[value].notna()
    if weight is None:
        w_orig = pd.Series(np.ones(len(df)), index=df.index)
    else:
        w_orig = pd.to_numeric(df[weight], errors="coerce")
        if not np.issubdtype(w_orig.dtype, np.number):
            raise TypeError(
                f"[cso_toolkit.dw_nestweight] Weight column {weight!r} "
                "could not be coerced to numeric.\n"
                "  Fix: clean the weight column upstream (drop non-numeric "
                "rows or cast to numeric) before calling."
            )

    stratum = df[by]
    if stratum.isna().any():
        warnings.warn(
            f"`{by}` has {int(stratum.isna().sum())} NA stratum value(s); "
            "those rows get weight 0.",
            stacklevel=2,
        )

    eligible = v_obs & w_orig.notna() & stratum.notna()
    if only is not None:
        if len(only) != len(df) or only.dtype != bool:
            raise ValueError(
                "[cso_toolkit.dw_nestweight] `only` must be a boolean "
                f"Series of length len(data) ({len(df)}); got "
                f"length {len(only)} with dtype {only.dtype!r}.\n"
                "  Fix: build the mask from the same DataFrame, e.g. "
                "`only = df['answered_q']` (a boolean column)."
            )
        eligible &= only.values

    total_w_by = w_orig.groupby(stratum, dropna=False).sum()
    eligible_w_by = (w_orig * eligible.astype(float)).groupby(stratum, dropna=False).sum()

    scale_by = np.where(eligible_w_by > 0, total_w_by / eligible_w_by, 0.0)
    scale_map = pd.Series(scale_by, index=total_w_by.index)
    scale_per_row = stratum.map(scale_map).fillna(0.0)

    w_new = np.where(eligible, w_orig * scale_per_row, 0.0)
    df[new_weight] = w_new

    if verbose:
        n_strata = total_w_by.shape[0]
        n_eligible = int(eligible.sum())
        n_total = len(df)
        print(
            f"dw_nestweight(): {n_strata} stratum levels; "
            f"{n_eligible}/{n_total} observations eligible."
        )
        v_num = pd.to_numeric(df[value], errors="coerce")
        if v_num.notna().any() and np.issubdtype(v_num.dtype, np.number):
            orig_mean = np.average(
                v_num.fillna(0), weights=w_orig.where(v_num.notna(), 0).fillna(0)
            ) if w_orig.where(v_num.notna(), 0).sum() else float("nan")
            adj_mean = np.average(
                v_num.fillna(0),
                weights=pd.Series(w_new).where(v_num.notna(), 0).fillna(0)
            ) if pd.Series(w_new).where(v_num.notna(), 0).sum() else float("nan")
            print(f"  Pooled mean of `{value}`:")
            print(f"    weighted by `{'(unit)' if weight is None else weight}`         : {orig_mean:.6g}")
            print(f"    weighted by `{new_weight}` (nestweighted): {adj_mean:.6g}")
        else:
            print(
                f"  (`{value}` is non-numeric "
                f"({df[value].dtype}); pooled mean diagnostic skipped.)"
            )

    return df
