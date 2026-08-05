from __future__ import annotations

import os
from pathlib import Path
import sys


CERTIFICATION_ROOT = Path(__file__).resolve().parent
SERVICE_ROOT = CERTIFICATION_ROOT.parents[1]
for path in (SERVICE_ROOT, CERTIFICATION_ROOT):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from run_certification import _locked_pythonpath  # noqa: E402


def test_locked_pythonpath_starts_with_selected_interpreter_environment() -> None:
    entries = _locked_pythonpath().split(os.pathsep)

    assert Path(entries[0]).resolve() == SERVICE_ROOT.resolve()
    assert Path(entries[1]).resolve() == (
        Path(sys.prefix) / "Lib" / "site-packages"
    ).resolve()
    assert Path(entries[1]).is_dir()
