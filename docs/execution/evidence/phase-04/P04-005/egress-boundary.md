# P04-005 egress boundary

- Assumption: no production Tool egress approval or provider endpoint is proven by the repository. This task therefore defines only three static typed specs and an injected adapter boundary; it performs no network call and accepts no URL or dynamic endpoint.
- Impact: registry lookup, canonical argument validation, policy/reservation ordering, bounded attempts, typed evidence references, timeout/provider errors, redirect refusal, and response-size limits are locally testable. Provider correctness and live egress remain pending external evidence and are not claimed.
- Fail-closed behavior: unknown or forbidden tool names return `tool.unknown` safe JSON with zero fallback execution; arbitrary URL/SQL/file/path/identity arguments return `tool.invalid_args`; policy/reservation failures happen before handler invocation.
- Rollback: disable the unmounted Tool path and remove these files. No MCP, dynamic discovery, remote push, merge, production call/write, or acceptance was performed.
