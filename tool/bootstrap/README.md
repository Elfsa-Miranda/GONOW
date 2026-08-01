# BOOT-005 isolated toolchain

This directory contains repository-owned adapters and exact package locks. The
executables and caches live under `D:\GO_NOW-toolchain`; no tool is installed
system-wide. `object_store_adapter.py` is local/provisional only and cannot
satisfy the formal immutable-architecture registration gate.

Direct dependency sources and licenses:

- `jsonschema==4.26.0`: PyPI, MIT.
- `PyYAML==6.0.3`: PyPI, MIT; callers must use `safe_load` or a stricter loader.
- `pip-audit==2.10.1`: PyPI/PyPA, Apache-2.0.
- `supabase==2.110.0`: npm/Supabase CLI, MIT.

Telemetry is disabled when invoking the Supabase CLI by setting
`SUPABASE_TELEMETRY_DISABLED=1` and `DO_NOT_TRACK=1`.
