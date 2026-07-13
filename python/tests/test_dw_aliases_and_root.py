"""Track T1 parity: the dw_* aliases, dw_root, and dw_default_unicef_allowlist.

Closes the T0 asymmetry where the canonical ``dw_*`` spellings raised
``ImportError`` in Python (the aliases were never exported). Mirrors the R
package, which exports both the bare and the ``dw_``-prefixed names.
"""

from __future__ import annotations

import pytest

import cso_toolkit as m

# (dw_-prefixed alias, bare name) pairs that R exports as dual names.
ALIAS_PAIRS = [
    ("dw_aggregate_data", "aggregate_data"),
    ("dw_aggregate_data_v2", "aggregate_data_v2"),
    ("dw_apply_time_window", "apply_time_window"),
    ("dw_generate_agg_footnote", "generate_agg_footnote"),
    ("dw_generate_markdown_report", "generate_markdown_report"),
    ("dw_process_all_csv_files", "process_all_csv_files"),
    ("dw_create_sector_script", "create_sector_script"),
    ("dw_create_profile", "create_profile"),
    ("dw_review_profile", "review_profile"),
    ("dw_test_scripts", "test_scripts"),
]


@pytest.mark.parametrize("alias, bare", ALIAS_PAIRS)
def test_alias_importable_and_identical(alias, bare):
    # the canonical dw_* spelling no longer raises ImportError...
    assert hasattr(m, alias), f"{alias} not exported"
    # ...and it is the SAME object as the bare name (an alias, not a copy)
    assert getattr(m, alias) is getattr(m, bare)


@pytest.mark.parametrize("alias, _bare", ALIAS_PAIRS)
def test_alias_in_dunder_all(alias, _bare):
    assert alias in m.__all__


def test_dw_root_returns_configured_root():
    from cso_toolkit import _state
    _state.configure(teamsWrkData="/tmp/wrk", teamsRawData="/tmp/raw", dwMetaData="/tmp/meta")
    assert m.dw_root("wrk") == "/tmp/wrk"
    assert m.dw_root("raw") == "/tmp/raw"
    assert m.dw_root("meta") == "/tmp/meta"
    assert m.dw_root() == "/tmp/wrk"  # default kind is wrk


def test_dw_root_none_when_unset(monkeypatch):
    from cso_toolkit import _state
    monkeypatch.setattr(_state, "dwMetaData", None, raising=False)
    assert m.dw_root("meta") is None  # matches R's NULL for an unset root


def test_dw_root_rejects_unknown_kind():
    with pytest.raises(ValueError):
        m.dw_root("bogus")


def test_dw_default_unicef_allowlist():
    al = m.dw_default_unicef_allowlist()
    assert isinstance(al, tuple)
    assert al == (
        r"^https://raw\.githubusercontent\.com/unicef-drp/",
        r"^https://github\.com/unicef-drp/",
    )
