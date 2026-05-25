"""Session-level state for cso-toolkit Python helpers.

The R helpers read mode-aware path globals from ``.GlobalEnv`` (set by
``profile_DW-Production.R``).  The Python equivalent reads them from
this module's globals, set by the consumer's profile
(``profile_DW-Production.py``).

Two equivalent ways to configure:

>>> from cso_toolkit import _state as state
>>> state.dw_mode = "producer"
>>> state.teamsWrkData = "/path/to/wrk"

Or via the :func:`configure` helper for batch setup:

>>> from cso_toolkit import _state as state
>>> state.configure(dw_mode="producer", teamsWrkData="/path/to/wrk")

All cso-toolkit helpers read through :func:`_get`, which returns ``None``
for unset names — equivalent to the R ``.try_get`` helper.
"""

from __future__ import annotations

from typing import Any, Optional

# ---------------------------------------------------------------------------
# Path roots (set by profile_<repo>.py)
# ---------------------------------------------------------------------------

#: Sandbox / mode-aware working-data root.
teamsWrkData: Optional[str] = None

#: Sandbox / mode-aware raw-data root.
teamsRawData: Optional[str] = None

#: Metadata root (sector schemas, codelists, ...).
dwMetaData: Optional[str] = None

#: Canonical (read-only) Teams root.
teamsFolder: Optional[str] = None

#: Canonical Teams root used by ``dw_is_canonical``.
teamsFolderCanonical: Optional[str] = None

#: Canonical working-data root used as the reviewer-mode read fallback.
teamsWrkDataCanonical: Optional[str] = None

#: Canonical raw-data root used as the reviewer-mode read fallback.
teamsRawDataCanonical: Optional[str] = None

# ---------------------------------------------------------------------------
# Mode contract
# ---------------------------------------------------------------------------

#: One of ``"producer"`` or ``"reviewer"``.  Set by the profile.
dw_mode: Optional[str] = None

#: When ``True``, helpers may hit external APIs.  Set by the profile
#: from ``dw_mode == "producer"``.
dw_apis_allowed: bool = False

# ---------------------------------------------------------------------------
# Z: drive mirror
# ---------------------------------------------------------------------------

#: Mount point of the Z: drive (typically ``"Z:/"`` on Windows).
dwZDrive: Optional[str] = None

#: Set by the profile to ``True`` if Z: is reachable, ``False`` otherwise.
dw_z_available: bool = False

# ---------------------------------------------------------------------------
# Manifest lookup
# ---------------------------------------------------------------------------

#: Path to the consumer's ``00_functions/`` folder (next to the vendored
#: helpers).  Used by :func:`cso_toolkit.cso_toolkit_sync` to find
#: ``.toolkit_manifest.yml``.
dwFunct: Optional[str] = None


# ---------------------------------------------------------------------------
# Configure helper
# ---------------------------------------------------------------------------

_PUBLIC_KEYS = (
    "teamsWrkData", "teamsRawData", "dwMetaData",
    "teamsFolder", "teamsFolderCanonical",
    "teamsWrkDataCanonical", "teamsRawDataCanonical",
    "dw_mode", "dw_apis_allowed",
    "dwZDrive", "dw_z_available",
    "dwFunct",
)


def configure(**kwargs: Any) -> None:
    """Batch-assign multiple session globals.

    Raises ``AttributeError`` for unknown keys so typos surface immediately
    rather than silently creating new attributes.

    Parameters
    ----------
    **kwargs
        Any of the module's public state keys (see source for the list).
    """
    for key, value in kwargs.items():
        if key not in _PUBLIC_KEYS:
            raise AttributeError(
                f"_state.configure: unknown key {key!r}. "
                f"Allowed keys: {', '.join(_PUBLIC_KEYS)}"
            )
        globals()[key] = value


def _get(name: str, default: Any = None) -> Any:
    """Safe accessor.  Equivalent to R's ``.try_get`` helper.

    Returns ``default`` (default ``None``) when ``name`` is not set or
    is bound to a falsy value.

    Parameters
    ----------
    name
        Name of a state global.
    default
        Value returned when ``name`` is unset.
    """
    value = globals().get(name)
    return value if value is not None else default
