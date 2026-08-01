from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.evidence_gate import (  # noqa: E402
    EvidenceError,
    EvidenceLedger,
    EvidenceRecord,
    EvidenceStatus,
)


def _record(status=EvidenceStatus.VERIFIED_CURRENT) -> EvidenceRecord:
    return EvidenceRecord(
        evidence_id="ev_one",
        source_kind="tool",
        source_ref="evidence://one",
        sha256="a" * 64,
        claim_ids=("claim_one",),
        status=status,
        version=1,
    )


def test_22_evidence_ledger_s_preserves_verified_current_record() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record())
    assert ledger.records_for_claim("claim_one")[0].status is EvidenceStatus.VERIFIED_CURRENT


def test_22_evidence_ledger_i_preserves_stale_or_conflicted_status() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record(EvidenceStatus.STALE))
    assert ledger.records_for_claim("claim_one")[0].status is EvidenceStatus.STALE


def test_22_evidence_ledger_i_rejects_history_overwrite() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record())
    with pytest.raises(EvidenceError, match="evidence.invalid"):
        ledger.append(_record(EvidenceStatus.INVALID))


def test_22_evidence_ledger_d_repository_failure_closes_claims() -> None:
    with pytest.raises(EvidenceError, match="evidence.invalid"):
        EvidenceLedger(available=False).records_for_claim("claim_one")
