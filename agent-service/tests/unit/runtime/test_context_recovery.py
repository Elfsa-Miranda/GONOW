from __future__ import annotations

from pathlib import Path
import site
import sys

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context_recovery import (  # noqa: E402
    ContextRecoveryError,
    compact_authorized_evidence,
    rehydrate_context_handle,
)
from app.rag.single_agent import SingleAgentKnowledgeEvidence  # noqa: E402


def _evidence(suffix: str, text: str, *, digest: str | None = None):
    return SingleAgentKnowledgeEvidence(
        claim_id=f"knowledge_{suffix * 16}",
        evidence_id=f"ev_knowledge_{suffix * 16}",
        source_ref=(
            "evidence://knowledge/"
            + "a" * 64
            + f"/30000000-0000-4000-8000-00000000000{suffix}"
        ),
        sha256=digest or suffix * 64,
        text=text,
        source_class="first_party_product_knowledge",
        license_identifier="first-party",
    )


def test_extractive_compaction_is_deterministic_exact_and_deduplicated() -> None:
    source = _evidence(
        "1",
        "Museum opens at nine. Unrelated filler sentence. Museum closes at five.",
    )
    duplicate = _evidence("2", "different projection", digest=source.sha256)
    decisions = [
        compact_authorized_evidence(
            (duplicate, source),
            query_terms=("museum",),
            max_total_characters=48,
        )
        for _ in range(3)
    ]

    assert len({item.digest for item in decisions}) == 1
    assert decisions[0].deduplicated_evidence_ids == (duplicate.evidence_id,)
    assert len(decisions[0].included) == 1
    record = decisions[0].compression_records[0]
    assert record.extracted_text == "Museum opens at nine.\nMuseum closes at five."
    assert all(source.text[span.start:span.end] == span.text for span in record.spans)
    assert record.original_characters == len(source.text)
    assert record.final_characters == len(record.extracted_text)


def test_omitted_evidence_has_handle_and_rehydration_rechecks_authority() -> None:
    first = _evidence("1", "Museum hours and ticket rules.")
    second = _evidence("2", "Long optional evidence. " * 40)
    decision = compact_authorized_evidence(
        (first, second),
        query_terms=("museum",),
        max_total_characters=35,
    )
    assert tuple(item.claim_id for item in decision.included) == (first.claim_id,)
    assert tuple(item.claim_ids for item in decision.handles) == ((second.claim_id,),)

    handle = decision.handles[0]
    assert rehydrate_context_handle(
        handle,
        resolver=lambda _: second,
        authorize=lambda _: True,
    ) == second
    with pytest.raises(ContextRecoveryError, match="context.rehydration_denied"):
        rehydrate_context_handle(
            handle,
            resolver=lambda _: second,
            authorize=lambda _: False,
        )
    with pytest.raises(ContextRecoveryError, match="context.rehydration_stale"):
        rehydrate_context_handle(
            handle,
            resolver=lambda _: second.model_copy(update={"sha256": "f" * 64}),
            authorize=lambda _: True,
        )
