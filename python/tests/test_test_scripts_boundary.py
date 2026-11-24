"""The Python auditor's call patterns need a left boundary (#237).

`my_read_csv(` is not pandas, and neither is `pl.read_csv(` (polars); the
module-qualified and bare forms the rules mean to catch still are. Mirrors
the lookbehind R's patterns use.
"""

from __future__ import annotations

import pytest

import cso_toolkit as m


def _rules(tmp_path, line: str) -> list:
    d = tmp_path / "scripts"
    d.mkdir(exist_ok=True)
    (d / "s.py").write_text(line + "\n", encoding="utf-8")
    return m.test_scripts(str(d), verbose=False)["rule"].tolist()


@pytest.mark.parametrize("line, rule", [
    ("df = pd.read_csv(p)", "io-read-csv"),
    ("df = pandas.read_csv(p)", "io-read-csv"),
    ("df = read_csv(p)", "io-read-csv"),
    ("df = pd.read_parquet(p)", "io-read-parquet"),
    ("x = json.load(fh)", "io-json"),
    ("r = requests.get(u)", "api-requests"),
    ("r = urllib.request.urlopen(u)", "api-urllib"),
    ("d = wbgapi.data.DataFrame(i)", "api-wbgapi"),
])
def test_calls_the_rules_mean_are_flagged(tmp_path, line, rule):
    assert rule in _rules(tmp_path, line)


@pytest.mark.parametrize("line, rule", [
    ("df = my_read_csv(p)", "io-read-csv"),
    ("df = pl.read_csv(p)", "io-read-csv"),
    ("df = pl.read_parquet(p)", "io-read-parquet"),
    ("x = orjson.loads(b)", "io-json"),
    ("x = myjson.load(fh)", "io-json"),
    ("r = self.requests.get(u)", "api-requests"),
])
def test_lookalikes_are_not_flagged(tmp_path, line, rule):
    assert rule not in _rules(tmp_path, line)
