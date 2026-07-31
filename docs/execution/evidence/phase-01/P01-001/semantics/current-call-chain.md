# P01-001 current call-chain baseline

This document records only code visible in the local Phase 1 base. It does not infer a private backend, production schema, RLS policy, deployment, or successful external model call. Those facts remain `unknown` unless named evidence is later supplied.

## Ordinary AI chat

1. `AiCustomScreen._sendMessage` accepts the current text (or a fixed prompt fallback), appends it to in-memory history, and attempts an `ai_chat_messages` insert when a Supabase user exists.
2. `_enrichUserInput` may add weather text returned by `AmapService`; the location/navigation branch is a comment-only placeholder.
3. The screen reads the current Supabase access token and current itinerary `planData`, then calls `AiGatewayService.sendChat`.
4. `AiGatewayService` admits only a compile-time-enabled HTTPS base whose host equals the compile-time allowlist and whose fixed path is `/v1/release-a/chat`. It sends bounded chat messages, source, and current plan. It accepts JSON containing non-empty `content`, optional broad-map `itinerary_data`, and optional `request_id`.
5. The screen displays the content and best-effort inserts the assistant message and broad-map itinerary data into `ai_chat_messages`.
6. Gateway disabled/misconfigured, missing auth, timeout, network, HTTP, media-type, size, or response-shape failure produces a fixed user-facing error. There is no direct-provider fallback. Cancel closes only the local HTTP client and clears UI state; there is no persistent server cancel intent in this phase.

Unknowns: the gateway implementation, server authorization, model/provider behavior, spend controls, production table shape, grants, and RLS are not present in the repository.

## AI itinerary import

The import button is shown only when the gateway response includes `itinerary_data`. `_importPlan` asks for a start date, parses the broad map through `ItineraryModel.fromJson`, normalizes dates, and calls `ItineraryProvider.saveItinerary`. That provider updates memory first, then attempts an `itineraries` insert/upsert and persists SharedPreferences; cloud failure retains a local copy. Parse/save failure keeps the existing itinerary and appends a fixed system error.

This is a current compatibility path, not the target Candidate/Domain Command boundary: warning/hard/unverified states, versioned schema validation, explicit user confirmation receipt, server authorization, CAS on initial import, and outbox delivery are not yet represented.

## Itinerary read, edit, synchronization, and rollback

- Startup reads per-user SharedPreferences first, then selects owned `itineraries` and joined `itinerary_members`; cloud failure falls back to local cache.
- Realtime subscribes to `public:itineraries:id=eq.<id>` and ignores updates whose numeric version is not greater than the current in-memory version.
- New saves use insert or upsert and then persist the returned UUID locally.
- Edits call `updateItineraryDataWithLock`: read cloud version, update by `id + version`, and increment version. If cloud is ahead, the client reloads it and retries once, but applies the locally edited whole `plan_data`; this is not a field-level three-way merge.
- Non-UUID or missing-cloud-row edits fall back to local-only persistence. General update exceptions return failure rather than silently declaring cloud success.
- `rollbackItineraryData` restores a snapshot locally for non-UUID rows, but for cloud rows performs an update by `id` without CAS or an explicit user guard.
- Delete removes local state first and then deletes cloud data by `id + user_id` when a logged-in user and UUID are available.

Unknowns: reproducible schema/RLS/grants, membership authorization, production Realtime policy, conflict loss rate, and whether every cloud write is tenant-safe.

## Direct client model paths still present but disabled

Itinerary polish/node-completion and diary generation/polish/copilot code still builds direct-provider HTTP requests and parses free-form or JSON responses. `AiConfig.deepseekEndpoint`, `deepseekModel`, and `deepseekApiKey` are permanent empty compatibility tombstones, so these paths fail before a useful provider request or return `null`/an error today. They are mapped for compatibility and removal; they are not an approved Agent boundary and must not be re-enabled with a client credential.

## Diary

`DiaryProvider` hydrates SharedPreferences, then selects the current user's diaries and public non-draft community rows. Save upserts a sanitized diary for an authenticated user and always updates local lists/cache; unauthenticated or failed cloud writes remain local. Delete attempts cloud deletion by diary ID and then removes all local copies even if the cloud call fails. Seed templates are merged when caches are empty or missing entries.

Cover upload tries `diary_photos` and then `itinerary_photos`. The diary AI generation, text polish, and detail-screen copilot remain direct-provider compatibility paths described above.

Unknowns: diary/storage schemas, ownership constraints, RLS/storage policies, delete authorization, public-data moderation, and production retention/deletion behavior.

## Authentication and other fallbacks

`AuthProvider` calls Supabase sign-up, password sign-in, anonymous sign-in, sign-out, password reset, and password update. Anonymous sign-in also upserts a `profiles` row. There is no repository proof for production redirect configuration, token policy, profile RLS, or account-linking semantics.

Read-only map/weather calls use AMap. Routing may switch walking/driving mode and finally render a straight-line estimate; destination/image/pre-trip UI also has fixed defaults. These fallbacks affect display only and do not prove external correctness.

## Target handoff

Phase 1 freezes these visible semantics. Phase 2 creates a new top-level `agent-service/`; later phases move model output to typed Candidates and put confirmed business mutations behind server-side Domain Commands, CAS, authorization, and outbox. The legacy Flutter direct-provider paths are migration inputs, not the foundation of the new Agent runtime.
