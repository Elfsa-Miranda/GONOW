from __future__ import annotations

from pathlib import Path
import sys

import pytest


CERTIFICATION_ROOT = Path(__file__).resolve().parent
SERVICE_ROOT = CERTIFICATION_ROOT.parents[1]
for path in (SERVICE_ROOT, CERTIFICATION_ROOT):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from c2_security_performance_cost import (  # noqa: E402
    C2_DEDICATED_DATABASE_PORT,
    CertificationFailure,
    _admin_database_url,
)


def test_c2_dedicated_database_keeps_owner_and_admin_on_same_cluster() -> None:
    owner = (
        "postgresql+pg8000://gonow_migrator_test@127.0.0.1:"
        f"{C2_DEDICATED_DATABASE_PORT}/gonow_p03_test"
    )

    assert _admin_database_url(owner) == (
        "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:"
        f"{C2_DEDICATED_DATABASE_PORT}/gonow_p03_test"
    )


@pytest.mark.parametrize(
    "database_url",
    (
        "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55434/gonow_p03_test",
        "postgresql+pg8000://gonow_migrator_test:secret@127.0.0.1:55433/gonow_p03_test",
        "postgresql+pg8000://gonow_migrator_test@localhost:55433/gonow_p03_test",
        "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55433/production",
        "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55433/gonow_p03_test?sslmode=disable",
    ),
)
def test_c2_database_rejects_non_task_owned_endpoints(database_url: str) -> None:
    with pytest.raises(CertificationFailure, match="c2.database_not_task_owned"):
        _admin_database_url(database_url)
