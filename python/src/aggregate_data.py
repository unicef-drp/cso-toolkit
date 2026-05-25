"""Aggregation helpers (v1 + v2) and time-window utilities.

Python port of ``r/R/aggregate_data.R`` and ``r/R/aggregate_data_v2.R``.

* :func:`aggregate_data` — original v1 signature (mean / weighted_mean,
  optional global aggregate, population + country coverage).  Kept for
  back-compat.
* :func:`aggregate_data_v2` — enhanced cross-sector signature with
  ``weighted_mean`` / ``mean`` / ``sum`` / ``proportion`` methods,
  coverage threshold, metadata columns.
* :func:`generate_agg_footnote` — standardised footnote string for
  aggregated estimates.
* :func:`apply_time_window` — filter data to latest observation within
  a time window, with exemptions.
"""

from __future__ import annotations

from typing import Iterable, Optional, Sequence

import numpy as np
import pandas as pd


def _weighted_mean(values: pd.Series, weights: pd.Series) -> float:
    """NaN-safe weighted mean.  Returns ``NaN`` when no valid weight."""
    v = pd.to_numeric(values, errors="coerce")
    w = pd.to_numeric(weights, errors="coerce")
    mask = v.notna() & w.notna()
    if not mask.any() or w[mask].sum() == 0:
        return float("nan")
    return float(np.average(v[mask], weights=w[mask]))


# ---------------------------------------------------------------------------
# v1 — kept for back-compat
# ---------------------------------------------------------------------------

def aggregate_data(
    data: pd.DataFrame,
    value: str,
    weight: str,
    by: Sequence[str],
    global_: bool = True,
    method: str = "mean",
    pop_coverage: bool = False,
    country_coverage: bool = False,
) -> pd.DataFrame:
    """Aggregate data with optional weighting and global aggregation.

    Original v1 helper; kept for back-compat with code that does not yet
    use :func:`aggregate_data_v2`.  Calculates coverage of non-NA values
    and supports mean or weighted-mean aggregation.

    Parameters
    ----------
    data
        Input data frame.
    value
        Column name with the values to aggregate.
    weight
        Column name with weights for weighted aggregation.
    by
        Column names to group by.
    global_
        If ``True``, append a global aggregation row with each ``by``
        column set to ``"World"``.
    method
        ``"mean"`` (unweighted) or ``"weighted_mean"``.
    pop_coverage
        Include the ``Pop_Covered`` column.
    country_coverage
        Include the ``Country_Coverage`` column.

    Returns
    -------
    pd.DataFrame
        Aggregated data.
    """
    if method not in ("mean", "weighted_mean"):
        raise ValueError(f"method must be 'mean' or 'weighted_mean'; got {method!r}")

    df = data.dropna(subset=list(by)).copy()
    grp = df.groupby(list(by), dropna=False)

    val_num = pd.to_numeric(df[value], errors="coerce")
    w_num = pd.to_numeric(df[weight], errors="coerce")

    df["_total_weight"] = grp[weight].transform(lambda s: pd.to_numeric(s, errors="coerce").sum())
    df["_weight_non_na"] = np.where(val_num.notna(), w_num, 0)
    df["_non_na_count"] = np.where(val_num.notna(), 1, 0)

    def _agg(g: pd.DataFrame) -> pd.Series:
        v = pd.to_numeric(g[value], errors="coerce")
        w = pd.to_numeric(g[weight], errors="coerce")
        agg = v.mean() if method == "mean" else _weighted_mean(v, w)
        return pd.Series({
            "Aggregate": agg,
            "Pop_Covered": (g["_weight_non_na"].sum() / g["_total_weight"].iloc[0])
                            if g["_total_weight"].iloc[0] else 0.0,
            "Country_Coverage": int(g["_non_na_count"].sum()),
        })

    out = df.groupby(list(by), dropna=False, as_index=False).apply(
        _agg, include_groups=False,
    ).reset_index(drop=True)

    # Re-attach by columns (apply drops them with as_index=False in some pandas versions)
    if not all(b in out.columns for b in by):
        out = df.groupby(list(by), dropna=False).apply(_agg).reset_index()

    if not pop_coverage:
        out = out.drop(columns=["Pop_Covered"], errors="ignore")
    if not country_coverage:
        out = out.drop(columns=["Country_Coverage"], errors="ignore")

    if global_:
        v_all = pd.to_numeric(df[value], errors="coerce")
        w_all = pd.to_numeric(df[weight], errors="coerce")
        agg_all = v_all.mean() if method == "mean" else _weighted_mean(v_all, w_all)
        row = {
            "Aggregate": agg_all,
            "Pop_Covered": df["_weight_non_na"].sum() / w_all.sum() if w_all.sum() else 0.0,
            "Country_Coverage": int(df["_non_na_count"].sum()),
        }
        if not pop_coverage:
            row.pop("Pop_Covered")
        if not country_coverage:
            row.pop("Country_Coverage")
        for b in by:
            row[b] = "World"
            out[b] = out[b].astype(str)
        out = pd.concat([out, pd.DataFrame([row])], ignore_index=True)

    return out


# ---------------------------------------------------------------------------
# v2 — cross-sector enhanced
# ---------------------------------------------------------------------------

def aggregate_data_v2(
    data: pd.DataFrame,
    value: str,
    weight: str,
    by: Sequence[str],
    *,
    country_id: str = "REF_AREA",
    global_: bool = True,
    method: str = "weighted_mean",
    coverage_threshold: Optional[float] = None,
    pop_coverage: bool = True,
    country_coverage: bool = True,
    total_population: bool = False,
    number_affected: bool = False,
    global_label: str = "WORLD",
    validate: bool = True,
) -> pd.DataFrame:
    """Aggregate data v2 — enhanced for cross-sector use.

    Supports multiple aggregation methods, coverage thresholds, and
    automatic metadata generation.

    Parameters
    ----------
    data
        Input data frame.
    value
        Column name containing values to aggregate.
    weight
        Column name containing population weights.
    by
        Column names to group by.
    country_id
        Column name identifying countries.
    global_
        Include a global aggregation row.
    method
        One of ``"weighted_mean"`` (default), ``"mean"``, ``"sum"``,
        ``"proportion"``.
    coverage_threshold
        Minimum population coverage (0–1) to report aggregate.  ``None``
        means no threshold.
    pop_coverage, country_coverage
        Include the corresponding metadata columns.
    total_population, number_affected
        Include the corresponding metadata columns.
    global_label
        Label for the global aggregate row.
    validate
        Perform input validation.

    Returns
    -------
    pd.DataFrame
    """
    valid_methods = ("weighted_mean", "mean", "sum", "proportion")
    if method not in valid_methods:
        raise ValueError(f"method must be one of {valid_methods}; got {method!r}")

    if validate:
        required = list(dict.fromkeys([value, weight, *by]))
        missing = [c for c in required if c not in data.columns]
        if missing:
            raise ValueError(f"Missing required columns: {', '.join(missing)}")
        if country_coverage and country_id not in data.columns:
            import warnings as _warn
            _warn.warn(
                f"country_id column {country_id!r} not found. "
                "Country coverage will use row count.",
                stacklevel=2,
            )
        if coverage_threshold is not None and not (0 <= coverage_threshold <= 1):
            raise ValueError("coverage_threshold must be between 0 and 1")

    df = data.dropna(subset=list(by)).copy()
    val_num = pd.to_numeric(df[value], errors="coerce")
    w_num = pd.to_numeric(df[weight], errors="coerce")
    df["_weight_non_na"] = np.where(val_num.notna(), w_num, 0.0)
    df["_num_affected"] = np.where(val_num.notna(), (val_num / 100.0) * w_num, np.nan)

    has_country = country_id in df.columns

    def _agg(g: pd.DataFrame) -> pd.Series:
        v = pd.to_numeric(g[value], errors="coerce")
        w = pd.to_numeric(g[weight], errors="coerce")
        if method == "mean":
            agg = v.mean()
        elif method == "weighted_mean":
            agg = _weighted_mean(v, w)
        elif method == "sum":
            denom = w.sum()
            agg = (v.sum() / denom * 100.0) if denom else float("nan")
        else:  # proportion
            datapop = g["_weight_non_na"].sum()
            popaffected = g["_num_affected"].sum(skipna=True)
            agg = (popaffected / datapop * 100.0) if datapop else float("nan")

        total_w = w.sum()
        pop_cov = (g["_weight_non_na"].sum() / total_w) if total_w else 0.0

        if has_country:
            cov_country = g.loc[v.notna(), country_id].nunique()
            tot_country = g[country_id].nunique()
        else:
            cov_country = len(g)
            tot_country = len(g)

        return pd.Series({
            "Aggregate": agg,
            "Pop_Covered": pop_cov,
            "Country_Coverage": cov_country,
            "Total_Countries": tot_country,
            "Total_Population": total_w,
            "Data_Population": g["_weight_non_na"].sum(),
            "Number_Affected": g["_num_affected"].sum(skipna=True),
        })

    try:
        out = df.groupby(list(by), dropna=False).apply(
            _agg, include_groups=False
        ).reset_index()
    except TypeError:
        # Older pandas (<2.2) doesn't accept include_groups
        out = df.groupby(list(by), dropna=False).apply(_agg).reset_index()

    if coverage_threshold is not None:
        out["Aggregate"] = np.where(
            out["Pop_Covered"] >= coverage_threshold, out["Aggregate"], np.nan,
        )

    if global_:
        v_all = pd.to_numeric(df[value], errors="coerce")
        w_all = pd.to_numeric(df[weight], errors="coerce")
        if method == "mean":
            agg_all = v_all.mean()
        elif method == "weighted_mean":
            agg_all = _weighted_mean(v_all, w_all)
        elif method == "sum":
            denom_all = w_all.sum()
            agg_all = (v_all.sum() / denom_all * 100.0) if denom_all else float("nan")
        else:
            datapop = df["_weight_non_na"].sum()
            popaffected = df["_num_affected"].sum(skipna=True)
            agg_all = (popaffected / datapop * 100.0) if datapop else float("nan")
        total_w_all = w_all.sum()
        pop_cov_all = (df["_weight_non_na"].sum() / total_w_all) if total_w_all else 0.0
        if has_country:
            cov_country_all = df.loc[v_all.notna(), country_id].nunique()
            tot_country_all = df[country_id].nunique()
        else:
            cov_country_all = len(df)
            tot_country_all = len(df)
        global_row = {
            "Aggregate": agg_all,
            "Pop_Covered": pop_cov_all,
            "Country_Coverage": cov_country_all,
            "Total_Countries": tot_country_all,
            "Total_Population": total_w_all,
            "Data_Population": df["_weight_non_na"].sum(),
            "Number_Affected": df["_num_affected"].sum(skipna=True),
        }
        if coverage_threshold is not None and pop_cov_all < coverage_threshold:
            global_row["Aggregate"] = float("nan")
        for b in by:
            global_row[b] = global_label
            out[b] = out[b].astype(str)
        out = pd.concat([out, pd.DataFrame([global_row])], ignore_index=True)

    keep = list(by) + ["Aggregate"]
    if pop_coverage:
        keep.append("Pop_Covered")
    if country_coverage:
        keep += ["Country_Coverage", "Total_Countries"]
    if total_population:
        keep += ["Total_Population", "Data_Population"]
    if number_affected and method == "proportion":
        keep.append("Number_Affected")

    return out[keep]


# ---------------------------------------------------------------------------
# Footnote
# ---------------------------------------------------------------------------

def generate_agg_footnote(
    country_coverage: int,
    total_countries: int,
    pop_coverage: float,
    start_year: Optional[int] = None,
    end_year: Optional[int] = None,
    exemptions: Optional[Sequence[str]] = None,
    exclusions: Optional[Sequence[str]] = None,
) -> str:
    """Generate a standardised footnote for aggregated estimates.

    Parameters
    ----------
    country_coverage, total_countries
        Numerator / denominator for the ``N / M countries`` segment.
    pop_coverage
        Population-coverage fraction (0–1); rendered as an integer
        percent.
    start_year, end_year
        Optional year range prefix.
    exemptions, exclusions
        Optional suffixes for country lists treated specially.

    Returns
    -------
    str
    """
    text = (
        f"{country_coverage}/{total_countries} countries "
        f"({round(pop_coverage * 100)} % population coverage)"
    )
    if start_year is not None and end_year is not None:
        text = (
            f"Based on latest estimates from {start_year} to {end_year}. " + text
        )
    if exemptions:
        text += f". Exemptions: {', '.join(exemptions)}"
    if exclusions:
        text += f". Exclusions: {', '.join(exclusions)}"
    return text


# ---------------------------------------------------------------------------
# Time-window filter
# ---------------------------------------------------------------------------

def apply_time_window(
    data: pd.DataFrame,
    *,
    country_col: str = "REF_AREA",
    time_col: str = "TIME_PERIOD",
    start_year: int,
    end_year: int,
    exemptions: Optional[Sequence[str]] = None,
    exclusions: Optional[Sequence[str]] = None,
) -> pd.DataFrame:
    """Filter data to the latest observation within a time window.

    Within each country (``country_col``), keep the row with the latest
    ``time_col`` value if that latest year falls within
    ``[start_year, end_year]``.  Countries in ``exemptions`` keep their
    latest value regardless of the window; countries in ``exclusions``
    are dropped before ranking.

    Parameters
    ----------
    data
        Input data frame.
    country_col, time_col
        Column names for country identifier and year.
    start_year, end_year
        Inclusive window bounds.
    exemptions
        Countries whose latest observation is kept even when outside the
        window.
    exclusions
        Countries dropped before ranking.

    Returns
    -------
    pd.DataFrame
    """
    df = data.copy()
    if exclusions:
        df = df[~df[country_col].isin(exclusions)]
    if df.empty:
        return df

    year_num = pd.to_numeric(df[time_col], errors="coerce").astype("Int64").astype("float")
    df["_year_int"] = np.floor(year_num)

    # Rank (1 = latest) per country, ties broken stably
    df["_year_rank"] = (
        df.groupby(country_col)["_year_int"]
          .rank(method="first", ascending=False)
    )

    in_window = (df["_year_int"] >= start_year) & (df["_year_int"] <= end_year)
    is_exempt = df[country_col].isin(exemptions or [])
    eligible = (df["_year_rank"] == 1) & (in_window | is_exempt)

    out = df[eligible].drop(columns=[c for c in df.columns if c.startswith("_")])
    return out.reset_index(drop=True)
