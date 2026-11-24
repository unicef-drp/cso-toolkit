"""Mirror paths keep a UNC root's leading ``//`` (#225).

On Windows, :func:`cso_toolkit.dw_io._normalize` resolves a mapped network
drive (``Z:/``) to its UNC form (``//server/share``).  The Z: and Teams
mirror helpers used to collapse every ``//``, turning the UNC root into a
folder on the current drive, so Python never found Z:.  These tests stand
in a UNC root without touching the network: ``_normalize`` is replaced by
a pure string function.
"""

from __future__ import annotations

import pytest

from cso_toolkit import _state
from cso_toolkit import dw_io


@pytest.fixture
def unc_session(monkeypatch):
    monkeypatch.setattr(dw_io, "_normalize", lambda p: str(p).replace("\\", "/"))
    for key, value in {
        "dw_z_available": True,
        "dwZDrive": "//srv.file.core.windows.net/dapm-cso",
        "teamsFolderCanonical": "C:/Teams/DW",
        "teamsWrkData": "C:/repo/wrk", "teamsWrkDataCanonical": "C:/Teams/DW/wrk",
        "teamsRawData": "C:/repo/raw", "teamsRawDataCanonical": "//nas/teams/raw",
    }.items():
        monkeypatch.setattr(_state, key, value, raising=False)


def test_z_mirror_keeps_the_unc_root(unc_session):
    got = dw_io._dw_z_mirror_path("C:/Teams/DW/wrk/nt/x.csv")
    assert got == "//srv.file.core.windows.net/dapm-cso/wrk/nt/x.csv"


def test_teams_mirror_keeps_a_unc_canonical_root(unc_session):
    got = dw_io._dw_teams_mirror_path("C:/repo/raw/nt/x.csv")
    assert got == "//nas/teams/raw/nt/x.csv"


def test_remote_mirrors_end_to_end(unc_session):
    got = dw_io._dw_remote_mirrors("C:/repo/wrk/nt/x.csv")
    assert got == {"teams": "C:/Teams/DW/wrk/nt/x.csv",
                   "z": "//srv.file.core.windows.net/dapm-cso/wrk/nt/x.csv"}


@pytest.mark.parametrize("root, rel, want", [
    ("Z:/", "nt/x.csv", "Z:/nt/x.csv"),          # drive root keeps one slash
    ("Z:", "nt/x.csv", "Z:/nt/x.csv"),
    ("//srv/share/", "/nt/x.csv", "//srv/share/nt/x.csv"),
    ("/data/teams", "", "/data/teams"),
    ("/", "nt/x.csv", "/nt/x.csv"),
])
def test_join_under(root, rel, want):
    assert dw_io._join_under(root, rel) == want
