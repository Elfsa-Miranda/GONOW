# Planning Candidate contract

## Exposure status

Phase 4 defines an internal typed Candidate but adds no public planning endpoint to
`contracts/openapi/agent-api.yaml`. The OpenAPI remains the Phase 2 health and contract-
descriptor surface. Flutter and production traffic are not connected.

## Candidate fields

An `ItineraryCandidate` contains:

- schema version `1.0`;
- deterministic `candidate_id`;
- `run_id`, pinned `behavior_digest`, and `input_digest`;
- title and ordered typed days/items;
- citations supported only by verified claims; and
- sorted evidence references plus status `candidate`.

Unknown fields are rejected. Each item has a stable item ID, title, start minute, positive
duration, and referenced claim IDs. Day numbers and item times must be ordered and must not
overlap. Claim IDs in the itinerary and citations must match exactly.

## Evidence and failure semantics

Unverified or conflicted claims cannot support a citation. Missing schemas, unknown fields,
unsupported claims, invalid schedules, and citation mismatches fail closed with stable typed
errors. Repair is at most two rounds and terminates when the normalized issue set is unchanged.

Candidate is always a draft. It does not authorize a Domain Command, formal itinerary write,
outbox event, diary write, or automatic import. A later phase must present the Candidate and
diff to the user, receive confirmation, and execute an authorized CAS Domain Command.

## Consumer rules

- Display hard errors, warnings, unverified evidence, and conflicts without converting them
  into verified facts.
- Preserve the behavior/input digests when rendering or requesting a later confirmation.
- Do not accept a broad map or client-generated claim as a substitute for this typed shape.
- On Agent flag-off or service failure, use the documented legacy itinerary path; never restore
  a client-side provider secret or direct model call.
