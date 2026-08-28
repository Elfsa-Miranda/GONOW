# E0 synthetic gold-contract candidate

This directory freezes the pre-Graph evaluation input and mechanical labels for Phase 4. It contains 30 common planning cases and 10 boundary, contradictory, invalid, or unsatisfiable cases. Every identifier and zone name is synthetic; no production account, prompt, trip, coordinate, trace, or user-derived record is present.

`requests.jsonl` and `labels.jsonl` are joined one-to-one by stable `case_id`. The schema validates both record types. Labels define hard requirements, ordering and conflict rules, critical fields, warnings, and exact failure codes. Common cases may produce only a typed Candidate with `formal_write_count=0`; boundary cases must fail closed with no Candidate.

The manifest hashes raw UTF-8 bytes without newline or encoding normalization. Manifest files and the dataset subset are independently sorted by POSIX-relative path UTF-8 bytes. Absolute paths, `..`, duplicate paths, and Unicode/case-fold collisions are rejected before hashing. The manifest digest uses RFC 8785/JCS serialization.

All thresholds and dataset bytes are frozen before Graph implementation for local provisional work. Product, Eval, and Privacy approval remains `pending_external`; this candidate is not formally accepted and cannot authorize model calls, production data use, formal writes, push, merge, deployment, or release acceptance.
