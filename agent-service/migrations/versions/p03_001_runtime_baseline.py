"""Establish the empty GoNow runtime migration baseline.

Revision ID: p03_001_runtime_baseline
Revises:
Create Date: 2026-08-01 05:00:00+08:00
"""

from collections.abc import Sequence


revision: str = "p03_001_runtime_baseline"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Record the baseline without asserting unverified business schema."""


def downgrade() -> None:
    """The empty baseline has no domain object to remove."""
