from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.evidence_gate import (  # noqa: E402
    CitationAssembler,
    CitationError,
    EvidenceError,
    EvidenceLedger,
    EvidenceRecord,
    EvidenceStatus,
)


def _record(evidence_id: str, status: EvidenceStatus) -> EvidenceRecord:
    return EvidenceRecord(
        evidence_id=evidence_id,
        source_kind="tool",
        source_ref=f"evidence://{evidence_id}",
        sha256="b" * 64,
        claim_ids=("claim_one",),
        status=status,
        version=1,
    )


def test_23_citation_assembler_s_links_claim_to_verified_evidence() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record("ev_verified", EvidenceStatus.VERIFIED_CURRENT))
    assert CitationAssembler(ledger).assemble(("claim_one",))[0].evidence_id == "ev_verified"


def test_23_citation_assembler_i_rejects_missing_evidence() -> None:
    with pytest.raises(CitationError, match="citation.missing"):
        CitationAssembler(EvidenceLedger()).assemble(("claim_one",))


def test_23_citation_assembler_i_exposes_conflict_as_failure() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record("ev_verified", EvidenceStatus.VERIFIED_CURRENT))
    ledger.append(_record("ev_conflict", EvidenceStatus.CONFLICTED))
    with pytest.raises(CitationError, match="citation.missing"):
        CitationAssembler(ledger).assemble(("claim_one",))


def test_23_citation_assembler_d_ledger_failure_generates_no_citation() -> None:
    with pytest.raises(EvidenceError, match="evidence.invalid"):
        CitationAssembler(EvidenceLedger(available=False)).assemble(("claim_one",))
