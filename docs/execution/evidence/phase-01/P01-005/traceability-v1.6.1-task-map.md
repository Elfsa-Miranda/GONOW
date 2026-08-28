# v1.6.1 → AGENTS 1.4.0 → Phase / TASK / CT traceability

- source architecture: v1.6.1, sealed BOOT input SHA-256 `644ab9f5ad04a65383bb34b6628b49472d9f68b50fa3681aa46671f59794c3a6`
- execution constitution: AGENTS.md 1.4.0
- execution plan: execplan.md 1.4.0
- inventory rule: one row for each of the 39 explicit `[硬约束...]` marker occurrences in AGENTS.md 1.4.0; compound source lines are split into one row per marker
- unmapped hard constraint count: 0

## Current Fact (not target implementation evidence)

| Current Fact ID | Evidence boundary | Current result |
|---|---|---|
| CF-001 | AGENTS §1.1, pinned baseline | Flutter root application; no server Agent directory on the pinned remote baseline |
| CF-002 | AGENTS §1.1–§1.2 | Client model-call remnants and distributed import/write semantics exist; Phase 0 containment does not prove the future Agent architecture exists |
| CF-003 | AGENTS §1.1–§1.2 | Runtime DDL, durable jobs, complete RLS migrations, RAG, MCP, Agent CI/eval/replay are absent or unknown at the pinned baseline |
| CF-004 | TASK-P01-001 evidence | Existing chat/import/auth/fallback paths are compatibility inputs, not the new Agent implementation |

## Target Contract / Hard Constraint inventory

Every row below is a target or invariant. A task reference is where implementation or proof is scheduled; it is not a claim that the capability is already implemented. `contract-only` means no numbered CT was defined for that constraint and is therefore an explicit mapping, not an omission.

| HC ID | v1.6.1 chapter | AGENTS stable section | Hard constraint summary | First implementation / proof TASK | Numbered CT mapping | Owner | Evidence state |
|---|---|---|---|---|---|---|---|
| HC-001 | §4, §29 | §1.3, §3 | One repository and 34 Harness responsibilities are not 34 services | P02-001, all PXX-089/990 | contract-only | Architecture + Engineering | target_pending |
| HC-002 | §4, §22 | §1.3, §3 | Agent physical boundary is exactly `agent-api` + `agent-worker` | P02-001, P02-005, P02-008 | contract-only | Architecture + Engineering | target_pending |
| HC-003 | §25–§26 | §2.4 | Open P0/P1, data-loss, cross-tenant, or irreversible defects must be zero | every PXX-990 | CT-003/004/007/008 as applicable | Security + Engineering | invariant_gate |
| HC-004 | §4, §30 | §3 | Python 3.13, FastAPI 0.136.x, Pydantic v2, LangGraph/LangChain v1, SQLAlchemy 2, Alembic | P02-001; DB/Graph portions P03-001/P04-002 | contract-only | Architecture + Engineering | target_pending |
| HC-005 | §1, §29 | §3 | Release B Agent scope is multi-day itinerary planning only | P04-002, P04-009, P09-007 | contract-only | Product + Architecture | target_pending |
| HC-006 | §6–§7 | §3 | Release B has one planning Behavior and one bounded Graph | P04-002, P04-008 | CT-012/013 | Architecture + Engineering | target_pending |
| HC-007 | §15 | §3 | One primary model provider with two certified deterministic tiers | P04-004 | contract-only | Architecture + Security | target_pending |
| HC-008 | §16, §22 | §3 | At most POI/route/weather read-only Tools; no RAG/Memory/production Multi-Agent/Redis/open MCP in Release B | P04-005, P04-990 | CT-008 | Security + Product | target_pending |
| HC-009 | §22, §30 | §3 | Legacy deletion requires 100% rollout plus the remaining retirement gates | P09-008, P10-010 | contract-only | Product + Engineering | target_pending |
| HC-010 | §18, §25–§26 | §5.1 | Every prohibition in the security deny-list is non-relaxable | P02-002 onward; every PXX-990 | CT-003–011/014/015 as applicable | Security | invariant_gate |
| HC-011 | §18, §25–§26 | §5.2 | Cross-tenant canary leakage count is zero | P03-007, P11-005 | CT-007 | Security + Data | target_pending |
| HC-012 | §16 | §6.1 | Static Tool allowlist and at most three read-only Tools | P04-005 | CT-008 | Security + Domain | target_pending |
| HC-013 | §7, §19 | §6.1 | Bounded repair is at most two rounds | P07-003 | contract-only | Engineering + Product | target_pending |
| HC-014 | §19 | §6.3 Harness 21 | Output Schema repair cannot erase hard conflicts and cannot exceed two rounds | P04-007, P07-003 | contract-only | Engineering + Eval | target_pending |
| HC-015 | §23–§24 | §7.2 | Deterministic mandatory eval gates pass 100% | P04-000, P04-010, P10-005 | CT-008/010/012 as applicable | Eval + Product | target_pending |
| HC-016 | §23–§24 | §7.2 | Every mandatory suite passes 100%; no retry-to-green | P02-006 and every PXX-990 | all applicable CTs | Engineering + Security | invariant_gate |
| HC-017 | §24, §30 | §7.2 | Analyzer ratchet has `new_errors=0` | P00-006 | contract-only | Engineering | local_provisional_evidence_exists |
| HC-018 | §18, §26 | §7.3 CT-007 | Cross-tenant retrieval/read is empty and `acl_leakage_count=0` | P03-007, P11-005 | CT-007 | Security + Data | target_pending |
| HC-019 | §25–§26, §29 | §7.6 | Phase acceptance has zero secret/PII/auth/tenant/RLS/SSRF/SQL/prompt/tool high-risk findings | every PXX-990 | CT-003/004/007/008 | Security | invariant_gate |
| HC-020 | §24, §29–§30 | §9.2 | Rollout order is 1→5→20→50→100% | P10-007, P10-009, P10-010 | CT-012/013 | Product + Security + SRE | target_pending |
| HC-021 | §4, §22 | §9.3 | Compatibility gateway and release tooling add no Agent process; physical boundary remains two processes | P02-008, P10-010 | contract-only | Architecture | target_pending |
| HC-022 | §25–§26 | §9.3 | Leakage/authorization rollback lines remain zero regardless of calibrated hypotheses | P10-009, P10-010 | CT-003/004/007/008 | Security | target_pending |
| HC-023 | §29–§30 | §10 Phase 0 | Relative to BASE_SHA, new analyzer/test errors are zero | P00-006, P00-990 | contract-only | Engineering | local_provisional_passed |
| HC-024 | §4, §18, §30 | §10 Phase 2 | Service skeleton secret/PII scan is zero | P02-002, P02-004, P02-006 | CT-003/004 | Security + Engineering | target_pending |
| HC-025 | §17–§19, §26 | §10 Phase 3 | Real PostgreSQL cross-tenant leakage is zero | P03-007, P03-008 | CT-001/002/007/012/013 | Security + Data | target_pending |
| HC-026 | §6–§7, §15–§19 | §10 Phase 4 | One planning Graph, two certified routes, at most three read-only Tools | P04-002, P04-004, P04-005 | CT-008/012/013 | Architecture + Security | target_pending |
| HC-027 | §19 | §10 Phase 7 | Canonical repair is at most two rounds | P07-003, P07-006 | contract-only | Engineering + Eval | target_pending |
| HC-028 | §7, §29 | §10 Phase 8 | Research experiment has at most two read-only branches and never serves active users | P08-001, P08-002, P08-004 | CT-011 | Engineering + Security | target_pending |
| HC-029 | §23–§24, §29–§30 | §10 Phase 10 | Phase 10 high-risk findings are zero | P10-009, P10-010 | CT-001–014 as applicable | Release Board | target_pending |
| HC-030 | §18, §28 | §10 Phase 11 | Optional RAG has `ACL leakage=0` and deletion does not resurrect data | P11-005, P11-008, P11-010 | CT-007/015 | Data + Privacy + Security | conditional_target |
| HC-031 | §29–§30 | §10 Release B | Release B cross-tenant, authorization, forbidden Tool, unapproved write, and live/new-history secret findings are zero | P10-010 | all applicable CTs | Release Board | target_pending |
| HC-032 | §22, §30 | §3 | Legacy deletion requires at least two mobile App release cycles plus the remaining retirement gates | P09-008, P10-010 | contract-only | Product + Engineering | target_pending |
| HC-033 | §16 | §6.1 | Every `ToolSpec.max_attempts` is exactly 1 or 2 | P04-005 | CT-008 | Security + Domain | target_pending |
| HC-034 | §24, §30 | §7.2 | Final Release analyzer/test commands exit zero | REL-A/B/C gates | contract-only | Engineering | target_pending |
| HC-035 | §24, §29–§30 | §9.2 | Core-quality loss greater than 1 percentage point triggers rollback | P10-009, P10-010 | CT-012/013 | Product + Security + SRE | target_pending |
| HC-036 | §24, §29–§30 | §9.2 | Unapproved p95 cost increase greater than 15% triggers rollback | P10-008, P10-009, P10-010 | CT-012/013 | Product + SRE | target_pending |
| HC-037 | §23–§24, §29–§30 | §10 Phase 10 | Ordered, non-overlapping Release B observation is at least 31 days | P10-009, P10-010 | CT-012/013 | Release Board | target_pending |
| HC-038 | §29–§30 | §10 Release B | Release B ordered, non-overlapping observation is at least 31 days | P10-009, P10-010 | all applicable CTs | Release Board | target_pending |
| HC-039 | §29–§30 | §10 Release C | Release C activates exactly one capability work package at a time | P12-000, P12-002 | contract-only | Release Board | conditional_target |

## Completeness decision

- explicit AGENTS hard-constraint marker occurrences: 39
- mapped HC rows: 39
- duplicate HC IDs: 0
- rows without Phase/TASK: 0
- rows without CT disposition (`CT-*`, `all applicable CTs`, or `contract-only`): 0
- Current Fact rows mislabeled as implemented Target Contract: 0
- Target Contract rows claimed as Current Fact: 0
- unmapped hard constraint count: 0
