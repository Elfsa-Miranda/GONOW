# P01-001 current write-path baseline

All rows below are code facts, not production-database assertions. A client-side predicate is defense in depth only; tenant safety remains `unknown` until reproducible migrations, grants, and RLS are inspected.

| Sink | Current writers and guards | Local/offline behavior | Known weakness or unknown |
|---|---|---|---|
| `ai_chat_messages` | AI screen inserts user/assistant rows with current `user_id`; clear/prune delete by user or selected IDs | UI history remains in memory when backup fails | Schema, ID ownership, grants, RLS, retention, and delete safety unknown |
| `itineraries` create | `saveToSupabase` inserts or upserts `user_id`, model fields, version, and `plan_data` | `saveItinerary` retains memory and SharedPreferences on failure | Reproducible schema/RLS absent; initial import is not a typed confirmed Domain Command |
| `itineraries` edit | `updateItineraryDataWithLock` reads version and updates by `id + version`; retry uses cloud version | Non-UUID/missing row saves locally; exceptions return false | Retry overwrites whole local `plan_data`, not a field merge; authorization/RLS unknown |
| `itineraries` rollback | Cloud snapshot update filters by `id`; local snapshot restore for non-UUID | Local cache/list rewritten | Cloud rollback has no CAS or explicit `user_id`; final safety depends on unknown RLS |
| `itineraries` basic info | Client update includes model fields/plan data and, in visible paths, may filter `id + user_id` | Local model/cache updated | Guards vary by method; schema and RLS unknown |
| `itineraries` delete | Local removal first; cloud delete by `id + user_id` for UUID and current user | Failed cloud delete is logged after local removal | Remote/local divergence possible; database enforcement unknown |
| `itinerary_members` | Join/copy/share paths read or mutate membership in client code | UI reports failures | Membership uniqueness, invite authorization, grants, and RLS unknown |
| `activity_photos` | Photo upload may insert `user_id`, itinerary/activity identifiers, and URL; delete may filter only image URL | Plan data also stores image URLs | Record/storage ownership and cross-tenant delete safety unknown |
| Storage buckets | Itinerary and diary providers upload local files to travel/itinerary/diary bucket candidates | Some callers try another bucket or retain local data | Only avatar policy is reproducible in the base; other storage policies unknown |
| `diaries` | Provider selects, upserts authenticated sanitized rows, and deletes by diary ID | Unauthenticated/failing saves persist locally; delete clears local lists despite cloud failure | Delete lacks explicit user predicate; RLS, moderation, retention, and schema unknown |
| `profiles` | Anonymous sign-in upserts a profile for the returned user ID | Authentication failure returns false | Profile schema/RLS and account-linking semantics unknown |
| SharedPreferences | Itinerary current/list cache, diary lists, and related UI state | Primary offline fallback | No cross-device consistency, durable job, CAS, encryption-at-rest proof, or server audit |
| Release A gateway | AI screen sends authenticated chat/current plan to a fixed HTTPS endpoint | Fixed error; no provider fallback | Server implementation, provider call, budget, audit, and production deployment unknown |
| Legacy direct model HTTP | Itinerary/diary UI/provider code can construct provider requests | Empty compatibility tombstones make current paths fail closed/null | Must never be re-enabled with client secrets; responses are broad/free-form maps |

## Mutation ordering

- Chat writes the user history row before the gateway call and the assistant row afterward; either backup may fail independently.
- Itinerary creation and diary save optimistically update memory/local state around cloud operations, so a local success does not prove a cloud commit.
- Itinerary delete and diary delete can clear local state even when cloud deletion fails.
- The current client has no transactional outbox tying domain state to events.
- The current client has no server fencing token, durable job lease, or persistent cancellation state.

## Boundary for the new Agent

The new Agent must not call these Flutter providers as its write API. Model output remains a typed Candidate. Only a user-confirmed, authorized, version-checked Domain Command may mutate formal tables, and the command must emit its event through an outbox in the same database transaction. Until that server path exists, the tables and client methods above remain legacy compatibility paths.
