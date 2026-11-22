"""cso_toolkit_check() target-version alert (#106 item 4).  Mirror of
r/tests/testthat/test-cso-toolkit-check-target.R.
"""

from __future__ import annotations

import importlib
import logging

import pytest

import cso_toolkit as m
from cso_toolkit import _state
# The package exports the function cso_toolkit_sync(), which shadows the
# submodule of the same name as an attribute: take the module itself.
sync = importlib.import_module("cso_toolkit.cso_toolkit_sync")


@pytest.fixture
def manifest(tmp_path, monkeypatch):
    """Write a manifest and point dwFunct at it; returns a setter."""
    def _make(pulled: str, target: str | None = None, apis: bool = False):
        lines = ['source: "unicef-drp/cso-toolkit"', f'pulled_version: "{pulled}"']
        if target is not None:
            lines.append(f'target_version: "{target}"')
        (tmp_path / ".toolkit_manifest.yml").write_text("\n".join(lines) + "\n",
                                                        encoding="utf-8")
        monkeypatch.setattr(_state, "dwFunct", str(tmp_path), raising=False)
        monkeypatch.setattr(_state, "dw_apis_allowed", apis, raising=False)
    return _make


def test_t1_version_helpers():
    assert sync._cso_version_behind("v0.9.0", "v0.9.1") is True
    assert sync._cso_version_behind("v0.9.1", "v0.10.0") is True     # not lexical
    assert sync._cso_version_behind("v0.10.0", "v0.9.1") is False
    assert sync._cso_version_behind("0.9.1", "v0.9.1") is False
    assert sync._cso_version_behind("v1.0.0-rc1", "v1.0.0") is False
    assert sync._cso_version_behind("inrepo", "v0.9.1") is None
    assert sync._cso_tag("0.9.1") == "v0.9.1" and sync._cso_tag("v0.9.1") == "v0.9.1"


def test_t2_reviewer_target_ahead_warns(manifest):
    manifest("v0.9.0", "v0.9.1")
    with pytest.warns(UserWarning, match=r"\[cso_toolkit\.cso_toolkit_check\]") as rec:
        res = m.cso_toolkit_check(quiet=True)
    msg = str(rec[0].message)
    assert 'cso_toolkit_sync(target_version="v0.9.1")' in msg
    assert "cso_toolkit_pull(" not in msg and "re-pins the manifest" in msg   # #213
    assert "Fix:" in msg and "Reviewer mode: no network call" in msg
    assert res["behind_target"] is True and res["target_source"] == "manifest"
    assert res["upstream_version"] is None


def test_t3_quiet_false_logs_box(manifest, caplog):
    manifest("v0.9.0", "v0.9.1")
    with caplog.at_level(logging.WARNING, logger=sync._log.name):
        with pytest.warns(UserWarning):
            m.cso_toolkit_check(quiet=False)
    text = caplog.text
    assert "BEHIND its target version" in text
    assert 'cso_toolkit_sync(target_version="v0.9.1")' in text
    assert "cso_toolkit_pull(" not in text   # #213


def test_t4_argument_overrides_manifest(manifest, recwarn):
    manifest("v0.9.1", "v0.9.2")
    res = m.cso_toolkit_check(quiet=True, target_version="v0.9.1")
    assert res["behind_target"] is False and res["target_source"] == "argument"
    assert not [w for w in recwarn if "cso_toolkit_check" in str(w.message)]


def test_t5_ahead_or_inrepo_no_warning(manifest, recwarn):
    manifest("v0.10.0", "v0.9.1")
    assert m.cso_toolkit_check(quiet=True)["behind_target"] is False
    manifest("inrepo", "v0.9.1")
    assert m.cso_toolkit_check(quiet=True)["behind_target"] is None
    assert not [w for w in recwarn if "cso_toolkit_check" in str(w.message)]


def test_t6_reviewer_without_target_returns_none(manifest):
    manifest("v0.9.0")
    assert m.cso_toolkit_check(quiet=True) is None


def test_t7_producer_newer_upstream_logs_box_no_warning(manifest, monkeypatch, caplog, recwarn):
    manifest("v0.9.0", apis=True)
    monkeypatch.setattr(sync, "_cso_upstream_latest_tag", lambda *_: "v0.9.1")
    with caplog.at_level(logging.WARNING, logger=sync._log.name):
        res = m.cso_toolkit_check(quiet=False)
    assert res["updates_available"] is True and res["upstream_version"] == "v0.9.1"
    assert "newer cso-toolkit release" in caplog.text
    assert not [w for w in recwarn if "cso_toolkit_check" in str(w.message)]


def test_t8_vendored_ahead_of_upstream_not_behind(manifest, monkeypatch):
    manifest("v0.10.0", apis=True)
    monkeypatch.setattr(sync, "_cso_upstream_latest_tag", lambda *_: "v0.9.1")
    assert m.cso_toolkit_check(quiet=True)["updates_available"] is False


def test_t9_producer_behind_target_and_upstream_cites_target(manifest, monkeypatch):
    manifest("v0.9.0", "v0.9.1", apis=True)
    monkeypatch.setattr(sync, "_cso_upstream_latest_tag", lambda *_: "v0.9.2")
    with pytest.warns(UserWarning, match=r'target_version="v0\.9\.1"'):
        res = m.cso_toolkit_check(quiet=True)
    assert res["behind_target"] is True and res["updates_available"] is True
