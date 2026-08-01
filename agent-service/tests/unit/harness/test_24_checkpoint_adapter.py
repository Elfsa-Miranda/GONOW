from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.checkpoint import (  # noqa: E402
    CURRENT_ENVELOPE_VERSION,
    CorruptCheckpoint,
    UnsupportedCheckpointVersion,
    UnsafeCheckpoint,
    _canonical_json,
    _upgrade_envelope,
)


def test_24_checkpoint_adapter_s_canonical_roundtrip_is_deterministic() -> None:
    left, encoded_left, digest_left = _canonical_json(
        {"checkpoint": {"values": [1, 2]}, "metadata": {"source": "loop"}}
    )
    right, encoded_right, digest_right = _canonical_json(
        {"metadata": {"source": "loop"}, "checkpoint": {"values": (1, 2)}}
    )
    assert left == right
    assert encoded_left == encoded_right
    assert digest_left == digest_right


def test_24_checkpoint_adapter_i_secret_field_is_rejected() -> None:
    with pytest.raises(UnsafeCheckpoint, match="checkpoint.unsafe_state"):
        _canonical_json({"state": {"secret": "synthetic-canary"}})


def test_24_checkpoint_adapter_i_client_object_is_rejected() -> None:
    with pytest.raises(UnsafeCheckpoint, match="checkpoint.unsafe_state"):
        _canonical_json({"state": {"runtime": object()}})


def test_24_checkpoint_adapter_d_v1_envelope_upgrades_without_guessing() -> None:
    upgraded = _upgrade_envelope(
        {"version": 1, "checkpoint": {"id": "fixture"}, "metadata": {}},
        1,
    )
    assert upgraded == {
        "version": CURRENT_ENVELOPE_VERSION,
        "checkpoint": {"id": "fixture"},
        "metadata": {},
        "new_versions": {},
    }


def test_24_checkpoint_adapter_d_unknown_or_malformed_version_fails_closed() -> None:
    with pytest.raises(
        UnsupportedCheckpointVersion, match="checkpoint.unsupported_version"
    ):
        _upgrade_envelope({"version": 9}, 9)
    with pytest.raises(CorruptCheckpoint, match="checkpoint.corrupt"):
        _upgrade_envelope({"version": 1, "checkpoint": {}}, 1)
