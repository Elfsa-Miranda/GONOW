# Flutter / Agent service compatibility matrix

Status: local provisional target contract. It does not claim that `agent-api`, `agent-worker`, or the future DTOs already exist.

The future connection point is the `FlutterAgentPlanningService` boundary. Its only Release B product scope is itinerary planning. Flutter owns presentation and editable local state; `agent-api` owns authenticated control-plane behavior; `agent-worker` owns bounded model/tool execution; PostgreSQL owns durable Run/Job/Event facts; confirmed formal writes belong to `DomainCommandService` through CAS and outbox.

| Domain | Existing compatibility path | Future/new path | Flag behavior | Failure / rollback | Data owner |
|---|---|---|---|---|---|
| chat | Release A compatibility gateway | No Agent path | Unaffected | Stable error; never direct provider fallback | Compatibility gateway |
| import | Manual Flutter candidate import | Retained next to Agent candidate import | Unaffected | Preserve original input as importable draft | Flutter draft until confirmation |
| auth | Supabase client session | Server verifies and derives principal | Unaffected | Fail closed; no anonymous/client-asserted principal | Auth server / verified request context |
| fallback | Local safe state and manual recovery | Retained | Unaffected | No formal write and no direct model provider call | Flutter local compatibility state |
| itinerary planning | None in the new service boundary | `FlutterAgentPlanningService` -> `agent-api` -> durable job -> `agent-worker` -> typed Candidate | `agent_itinerary_planning_v1`, default off | Turn flag off for new Runs; preserve input; existing Runs use durable recovery | API/worker/PostgreSQL split by contract |

The supported old/new combinations are: flag off with compatibility paths only; flag on with a healthy planning service; flag on with the planning service unavailable while old chat/import/auth/fallback remain usable; and rollback with the flag off. No combination authorizes Flutter-to-provider calls, `agent-api` model execution, Worker domain writes, or Candidate-to-domain-write bypass.

Deletion is not part of this task. Existing chat, import, auth, fallback, parsing, and write adapters remain until every retirement prerequisite in `contracts/flutter-agent-boundary-v1.yaml` is met. Rollback is therefore a flag transition, not code deletion.
