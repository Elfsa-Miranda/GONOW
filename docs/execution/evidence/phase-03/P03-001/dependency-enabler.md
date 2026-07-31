# P03-001 dependency enabler

## Assumption

The Phase 3 card requires real Alembic/PostgreSQL execution but omits the mandatory SQLAlchemy, Alembic, and DBAPI dependencies from its write allowlist. Under AGENTS.md §0.4.1, this is handled as a minimal reversible enabler rather than mutating the frozen task catalog or pretending the tools already exist.

## Impact

- Adds exactly three pinned direct dependencies: Alembic 1.18.5, SQLAlchemy 2.0.51, and pg8000 1.31.5.
- Adds five new transitive packages: Mako 1.3.12, MarkupSafe 3.0.3, greenlet 3.5.4, scramp 1.4.15, and asn1crypto 1.5.1. `python-dateutil` and `six` were already locked.
- Repairs a license-metadata normalization defect without changing the approved-license set.
- Creates ADR-P03-001 because the DBAPI driver was not named in the approved §3 technology line. Formal adoption is pending; safe local testing may continue.
- Does not mutate `TaskGateCatalog.psd1`, public API, database schema, production state, or external systems.

## Root-cause closure

The first driver candidate, Psycopg 3.3.4, was removed after its `LGPL-3.0-only` metadata failed the unchanged repository policy. The selected pg8000 driver is BSD 3-Clause, but its installed string `BSD 3-Clause License` exposed a punctuation-normalization bug in the checker. The focused regression now recognizes both `BSD-3-Clause` and `BSD 3-Clause License`, while explicitly rejecting LGPL and unrelated proprietary text.

The focused regression passed (`1 passed`), and the complete locked SCA/license stage then passed with four successful gates, `unknown_license=0`, `unpinned_direct=0`, and zero audit findings. The machine reports and reproducible CycloneDX SBOM are retained beside this note.

## Rollback

Revert `pyproject.toml`, regenerate `uv.lock` from the prior commit, and revert the normalization helper/tests and ADR. No database object or external state depends on this enabler yet.
