"""cso-toolkit Python helpers.

Python port of the R helpers shipped at ``r/R/`` in the same repo.  Same
behaviour contract; mode-aware path routing, cached external-API access,
provenance sidecars, and version-drift detection.

The two main entry points mirror their R counterparts:

>>> from cso_toolkit import dw_save, dw_use, dw_api_fetch
>>> df = dw_use(name="dw_ed_edu.csv", sector="ed", kind="wrk")

Session state (mode, paths, Z: drive availability) is configured via
:mod:`cso_toolkit._state` — typically once at profile load time.
"""

from __future__ import annotations

from . import _state  # re-export the configuration module

# IO helpers (dw_io.py)
from .dw_io import (
    dw_compare,
    dw_default_unicef_allowlist,
    dw_is_canonical,
    dw_isid,
    dw_merge,
    dw_resolve_path,
    dw_root,
    dw_save,
    dw_toolkit_version,
    dw_use,
    dw_verify_z,
)

# API helpers (dw_api.py)
from .dw_api import (
    dw_api_cached,
    dw_api_fetch,
    dw_api_inventory,
)

# Sync helpers (cso_toolkit_sync.py)
from .cso_toolkit_sync import (
    cso_toolkit_check,
    cso_toolkit_diff,
    cso_toolkit_pull,
)

# Aggregation helpers (aggregate_data.py)
from .aggregate_data import (
    aggregate_data,
    aggregate_data_v2,
    apply_time_window,
    generate_agg_footnote,
)

# Survey-weight redistribution
from .dw_nestweight import dw_nestweight

# Demographics helpers
from .dw_pop import dw_pop

# Markdown reporter
from .generate_markdown_report import (
    generate_markdown_report,
    process_all_csv_files,
)

# Scaffolding
from .create_sector_script import (
    create_dw_sector_script,
    create_sector_script,
)
from .profile_helpers import (
    create_profile,
    review_profile,
)

# Contract auditor
from .test_scripts import test_scripts

# dw_-prefixed aliases of the bare-named helpers, mirroring the R package
# (R exports both names since v0.4.5). Same objects, not separate functions,
# so a caller can `from cso_toolkit import dw_aggregate_data` and the canonical
# dw_* spelling resolves identically across R and Python.
dw_aggregate_data = aggregate_data
dw_aggregate_data_v2 = aggregate_data_v2
dw_apply_time_window = apply_time_window
dw_generate_agg_footnote = generate_agg_footnote
dw_generate_markdown_report = generate_markdown_report
dw_process_all_csv_files = process_all_csv_files
dw_create_sector_script = create_sector_script
dw_create_profile = create_profile
dw_review_profile = review_profile
dw_test_scripts = test_scripts

__all__ = [
    "_state",
    # IO
    "dw_save", "dw_use", "dw_compare", "dw_merge", "dw_isid",
    "dw_verify_z", "dw_resolve_path", "dw_is_canonical",
    "dw_root", "dw_default_unicef_allowlist",
    "dw_toolkit_version",
    # API
    "dw_api_fetch", "dw_api_cached", "dw_api_inventory",
    # Sync
    "cso_toolkit_check", "cso_toolkit_diff", "cso_toolkit_pull",
    # Aggregation
    "aggregate_data", "aggregate_data_v2",
    "apply_time_window", "generate_agg_footnote",
    # Other
    "dw_nestweight",
    "dw_pop",
    "generate_markdown_report", "process_all_csv_files",
    "create_sector_script", "create_dw_sector_script",
    "create_profile", "review_profile",
    "test_scripts",
    # dw_-prefixed aliases (mirror the R dual names)
    "dw_aggregate_data", "dw_aggregate_data_v2", "dw_apply_time_window",
    "dw_generate_agg_footnote", "dw_generate_markdown_report",
    "dw_process_all_csv_files", "dw_create_sector_script",
    "dw_create_profile", "dw_review_profile", "dw_test_scripts",
]

__version__ = "0.7.0"
