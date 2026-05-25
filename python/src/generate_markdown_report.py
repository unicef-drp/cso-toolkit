"""Generate descriptive-statistics Markdown reports from CSV files.

Python port of ``r/R/generate_markdown_report.R``.

* :func:`generate_markdown_report` — process a single CSV.
* :func:`process_all_csv_files` — loop over a folder of CSVs.
"""

from __future__ import annotations

import datetime as _dt
import getpass
import os
import warnings
from pathlib import Path
from typing import List, Optional, Union

import numpy as np
import pandas as pd


def _fmt(x: float) -> str:
    """Format a number with comma thousands separators and ~2 sig figs."""
    if pd.isna(x):
        return ""
    if abs(x) >= 1 or x == 0:
        return f"{x:,.2f}"
    return f"{x:.3g}"


def _variable_details(data: pd.DataFrame) -> pd.DataFrame:
    """Build the per-variable summary table."""
    rows: List[List[str]] = []
    for name in data.columns:
        col = data[name]
        if pd.api.types.is_numeric_dtype(col):
            rows.append([
                name, "Numeric", str(col.nunique(dropna=True)),
                _fmt(col.mean()), _fmt(col.std()),
                _fmt(col.min()), _fmt(col.max()),
            ])
        else:
            rows.append([name, "String", str(col.nunique(dropna=True)),
                         "", "", "", ""])
    return pd.DataFrame(
        rows,
        columns=["Variable Name", "Type", "Unique Cases",
                 "Mean", "SD", "Min", "Max"],
    )


def _summarize(data: pd.DataFrame, group_var: str,
               value_var: str) -> Optional[pd.DataFrame]:
    """Summarise ``value_var`` grouped by ``group_var``."""
    if value_var not in data.columns:
        warnings.warn(
            f"Column {value_var!r} not found in data. "
            f"Skipping summary statistics for {group_var}.",
            stacklevel=2,
        )
        return None
    val = pd.to_numeric(data[value_var], errors="coerce")
    grouped = (
        data.assign(_value=val)
        .groupby(group_var, dropna=False)["_value"]
        .agg(N="count", Mean="mean", SD="std", Min="min", Max="max")
        .reset_index()
    )
    for col in ("N", "Mean", "SD", "Min", "Max"):
        grouped[col] = grouped[col].apply(_fmt) if col != "N" else grouped[col].astype(str)
    return grouped


def _md_table(df: pd.DataFrame) -> str:
    """Render a DataFrame as a GitHub-flavored Markdown table."""
    if df is None or len(df) == 0:
        return ""
    header = "| " + " | ".join(df.columns) + " |"
    sep = "|" + "|".join(["---"] * len(df.columns)) + "|"
    rows = ["| " + " | ".join(str(v) for v in row) + " |"
            for row in df.itertuples(index=False, name=None)]
    return "\n".join([header, sep, *rows])


def generate_markdown_report(
    csv_file_path: Union[str, Path],
    country_column: str,
    year_column: str,
    indicator_column: str,
    value_column: str,
    output_path: Optional[Union[str, Path]] = None,
) -> None:
    """Generate a descriptive-statistics Markdown report from one CSV.

    Reads the CSV at ``csv_file_path`` and writes a Markdown report
    containing a general preamble (filename, timestamp, user, number of
    observations, unique-country / -year / -indicator counts, number of
    variables), a variable-details table, and optional summary tables by
    country, year, and indicator (only when the corresponding columns
    are present).

    Parameters
    ----------
    csv_file_path
        Path to the input CSV.
    country_column, year_column, indicator_column
        Column names; absent columns are skipped silently.
    value_column
        Numeric column to summarise.
    output_path
        Directory to write ``<basename>.md`` into.  ``None`` writes to
        the current working directory.
    """
    csv_file_path = Path(csv_file_path)
    data = pd.read_csv(csv_file_path)  # cso-allow: io-read-csv

    time_date = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    user = os.environ.get("USERNAME") or getpass.getuser()
    filename = csv_file_path.name

    n_countries = data[country_column].nunique() if country_column in data.columns else None
    n_years = data[year_column].nunique() if year_column in data.columns else None
    n_indicators = data[indicator_column].nunique() if indicator_column in data.columns else None
    n_variables = len(data.columns)
    n_obs = len(data)

    var_details = _variable_details(data)

    summaries: dict[str, Optional[pd.DataFrame]] = {
        "Country": _summarize(data, country_column, value_column) if country_column in data.columns else None,
        "Year": _summarize(data, year_column, value_column) if year_column in data.columns else None,
        "Indicator": _summarize(data, indicator_column, value_column) if indicator_column in data.columns else None,
    }

    lines = [
        "# Descriptive Statistics Report",
        "",
        "## General Preamble",
        "",
        f"- **Filename**: {filename}",
        f"- **Date and Time**: {time_date}",
        f"- **User**: {user}",
        f"- **Number of Observations**: {n_obs}",
        f"- **Number of Unique Country Names**: {n_countries if n_countries is not None else 'N/A'}",
        f"- **Number of Unique Years**: {n_years if n_years is not None else 'N/A'}",
        f"- **Number of Unique Indicators**: {n_indicators if n_indicators is not None else 'N/A'}",
        f"- **Number of Variables in the Database**: {n_variables}",
        "",
        "## Variable Details Preamble",
        "",
        _md_table(var_details),
        "",
    ]

    section_labels = [("Country", country_column),
                      ("Year", year_column),
                      ("Indicator", indicator_column)]
    for label, col in section_labels:
        df = summaries[label]
        if df is None:
            continue
        lines.append(f"## Summary by {label}")
        lines.append("")
        lines.append(_md_table(df))
        lines.append("")

    out_name = csv_file_path.stem + ".md"
    out_file = Path(output_path) / out_name if output_path else Path(out_name)
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(lines), encoding="utf-8")
    print(f"Markdown report saved to {out_file}")


def process_all_csv_files(
    folder_path: Union[str, Path],
    country_column: str,
    year_column: str,
    indicator_column: str,
    value_column: str,
    output_path: Optional[Union[str, Path]] = None,
) -> None:
    """Generate descriptive-statistics reports for every CSV in a folder.

    Lists every ``.csv`` file in ``folder_path`` (non-recursive) and
    calls :func:`generate_markdown_report` on each.

    Parameters
    ----------
    folder_path
        Directory containing input CSVs.
    country_column, year_column, indicator_column, value_column
        Forwarded to :func:`generate_markdown_report`.
    output_path
        Output directory for ``.md`` files.
    """
    folder = Path(folder_path)
    for csv_file in sorted(folder.glob("*.csv")):
        print(f"Processing file: {csv_file}")
        generate_markdown_report(
            csv_file, country_column, year_column,
            indicator_column, value_column, output_path,
        )
