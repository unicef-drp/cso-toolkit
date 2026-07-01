"""Convenience wrapper for World Bank population indicators.

Python port of ``r/R/dw_pop.R``.  Thin wrapper around
:func:`cso_toolkit.dw_api_fetch` (``api="wb"``) for the World Bank
total-population indicator (``SP.POP.TOTL``).  Every UNICEF sector needs
a population denominator for weighted regional aggregates; pulling it
directly via ``dw_api_fetch`` requires the caller to remember the
indicator code, the cache key, and the column names.  :func:`dw_pop`
wraps all three and returns a tidy ``(REF_AREA, TIME_PERIOD,
OBS_VALUE)`` frame.

Mode contract: inherits whatever :func:`dw_api_fetch` enforces —
producer sessions can hit the network (and cache the result via
``dw_save``), reviewer sessions read the cached deposit only (no live
fetch).
"""

from __future__ import annotations

from typing import Optional, Sequence, Union

import pandas as pd

from .dw_api import dw_api_fetch


def dw_pop(
    year: Optional[Union[int, Sequence[int]]] = None,
    indicator: str = "SP.POP.TOTL",
    countries: Optional[Union[str, Sequence[str]]] = None,
    refresh: bool = False,
    cache_key: str = "wb_population_sp_pop_totl",
    verbose: bool = True,
) -> pd.DataFrame:
    """Latest country-level population numbers.

    Convenience wrapper around :func:`cso_toolkit.dw_api_fetch` for the
    World Bank total-population indicator (``SP.POP.TOTL``).  Returns a
    tidy frame suitable for use as a weight column in
    :func:`aggregate_data_v2` or for merging directly into a
    country-level dataset.

    When ``year`` is ``None`` (the default), only the latest available
    year per country is returned.  When a specific year (or sequence of
    years) is supplied, the frame is filtered to that subset.

    Parameters
    ----------
    year
        Year (or years) to keep.  ``None`` (default) returns the latest
        year per country.
    indicator
        World Bank indicator code.  Default ``"SP.POP.TOTL"`` (total
        population).
    countries
        ISO3 / M49 country code (or codes) to keep.  ``None`` (default)
        returns every country in the World Bank response.
    refresh
        When ``True`` and the session is in producer mode, force a live
        fetch and overwrite the cache.  Default ``False`` (cache-first).
    cache_key
        Cache filename basename forwarded to :func:`dw_api_fetch`.
        Default ``"wb_population_sp_pop_totl"``.
    verbose
        Print a one-line progress / result message.

    Returns
    -------
    pd.DataFrame
        A frame with columns ``REF_AREA``, ``TIME_PERIOD``,
        ``OBS_VALUE``.  Sorted by ``REF_AREA``, ``TIME_PERIOD``
        (ascending), with a fresh ``RangeIndex``.

    Examples
    --------
    >>> pop = dw_pop()                                   # doctest: +SKIP
    >>> pop_2023 = dw_pop(year=2023)                     # doctest: +SKIP
    >>> sahel = dw_pop(countries=["BFA", "MLI", "NER", "TCD"])  # doctest: +SKIP

    See Also
    --------
    dw_api_fetch : the underlying cache mechanics.
    """
    if verbose:
        span = "(latest/country)" if year is None else (
            f"year={','.join(str(y) for y in _as_list(year))}"
        )
        print(f"dw_pop(): population indicator={indicator} {span}")

    # Resolve via the standard API cache layer.
    raw = dw_api_fetch(api="wb", cache_key=cache_key, refresh=refresh,
                       indicator=indicator)

    if not isinstance(raw, pd.DataFrame):
        raw = pd.DataFrame(raw)

    # The wbstats / wbgapi response shape (post-2021) includes an ISO
    # code column, a date column, and a value column.  Some older
    # responses expose ``iso2c`` only, or a value column named after the
    # indicator itself; guard for each alternate.
    col_iso = _first_present(raw, ["iso3c", "iso2c"])
    col_date = _first_present(raw, ["date", "TIME_PERIOD"])
    col_val = _first_present(raw, ["value", "OBS_VALUE", indicator])
    if col_iso is None or col_date is None or col_val is None:
        raise RuntimeError(
            "[cso_toolkit.dw_pop] Unexpected World Bank response shape: "
            "missing one of (iso, date, value) columns.\n"
            f"  Got columns: {', '.join(map(str, raw.columns))}\n"
            "  Fix: re-run with `refresh=True` to repopulate the cache, "
            "or inspect the cache file directly."
        )

    tidy = pd.DataFrame({
        "REF_AREA": raw[col_iso],
        "TIME_PERIOD": pd.to_numeric(raw[col_date], errors="coerce"),
        "OBS_VALUE": pd.to_numeric(raw[col_val], errors="coerce"),
    })

    # Drop rows missing the key triplet; WB sometimes returns sparse obs
    # (e.g. regional aggregates with NA for some years).
    tidy = tidy.dropna(subset=["REF_AREA", "TIME_PERIOD", "OBS_VALUE"])
    tidy["TIME_PERIOD"] = tidy["TIME_PERIOD"].astype(int)
    tidy["OBS_VALUE"] = tidy["OBS_VALUE"].astype(float)

    # Country filter
    if countries is not None:
        keep = set(_as_list(countries))
        tidy = tidy[tidy["REF_AREA"].isin(keep)]

    # Year filter (or latest-per-country fallback)
    if year is not None:
        keep_years = {int(y) for y in _as_list(year)}
        tidy = tidy[tidy["TIME_PERIOD"].isin(keep_years)]
    else:
        # Latest year per country.
        tidy = tidy.sort_values(["REF_AREA", "TIME_PERIOD"],
                                ascending=[True, False])
        tidy = tidy.drop_duplicates(subset="REF_AREA", keep="first")

    # Stable sort: country, year ascending.
    tidy = tidy.sort_values(["REF_AREA", "TIME_PERIOD"]).reset_index(drop=True)

    if verbose:
        print(f"  returned {len(tidy)} rows")
    return tidy


def _as_list(x: Union[object, Sequence[object]]) -> list:
    """Normalise a scalar-or-sequence argument to a list."""
    if x is None:
        return []
    if isinstance(x, (str, bytes)):
        return [x]
    if isinstance(x, Sequence):
        return list(x)
    return [x]


def _first_present(df: pd.DataFrame, candidates: Sequence[str]) -> Optional[str]:
    """Return the first candidate column name present in ``df``."""
    for name in candidates:
        if name in df.columns:
            return name
    return None
