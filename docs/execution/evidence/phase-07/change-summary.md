# Phase 7 change summary

Status: local provisional; independent review and formal acceptance pending.

Before Phase 7, itinerary validation semantics were frozen as fixtures but there was no server-side
typed constraint envelope, canonical validator, bounded repair engine, five-state Evidence Gate, or
isolated optional solver. After this candidate:

- callers can express time, commute, opening-hours, budget, and preference constraints as strict
  versioned types;
- equal typed inputs produce stable hard/warning/unverified/verified classifications and reason
  codes;
- missing or unavailable evidence cannot silently become verified;
- local repair performs at most two rounds, stops on no progress, and retains unresolved original
  conflicts;
- OR-Tools is exact-locked, disabled by default, isolated in a child, parent-killed on hard timeout,
  and always returns a valid fallback on degradation;
- immutable Phase 1 compatibility fixtures replay 8/8 and the Phase 7 mandatory matrix replays 9/9;
- local quality slices report 9/9, 4/4, and 3/3 with zero errors, while production quality, latency,
  cost, and adoption remain explicitly unknown.

There is no new public endpoint, migration, production write, production activation, remote push,
or accepted release state in this phase.
