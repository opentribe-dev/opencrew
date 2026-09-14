# OpenCrew Backend Charter (Developer A: Backend / Protocol / Core Runtime)

Captured 2026-09-13 from the Developer A work assignment. This is the source-of-truth
brief that `docs/superpowers/plans/*` implement. Developer A owns `repos/server`,
`repos/protocol`, `repos/sdk`, `repos/cloud`. Developer B owns `repos/app`,
`repos/agentd`, `repos/website`, `repos/infra` and must not be edited except via a
documented "DEV B REQUEST".

## Goal

Build the OpenCrew backend and shared contracts required for v0.1: messaging, users,
agents, conversations, groups, mentions, replies, agent-to-agent messaging, memory,
model providers, Native Agent runtime, runtime sessions/bindings, authentication,
permissions, approvals, WebSockets, REST API, persistence, jobs, protocol schemas,
SDK, provider abstractions, Claude Subscription provider contracts, Anthropic/OpenAI/
OpenRouter-compatible providers, server-side integration with agentd, reconnect/replay,
transactional reliability.

## Architectural invariants (must not violate)

- Agent != Model. Agent != Runtime. Agent != Runtime Session.
- `Runtime Session = Agent + Conversation + Runtime + Workspace`.
- An Agent is a persistent identity: identity, personality, memory, model policy,
  tools, permissions, runtime profiles, relationships.
- The same Agent may use Native runtime, Claude Code, Codex, Gemini CLI, or other
  runtimes without becoming a different Agent.
- Vendor-specific session IDs must never live directly on the core Agent model —
  they belong on a `RuntimeBinding`/`RuntimeSession` record instead.

## Default self-host requirements

Lightweight by default: one server process, one exposed port, one persistent data
directory, SQLite + WAL, local attachment storage, built-in background jobs.
Must NOT require Postgres, Redis, Kafka, NATS, RabbitMQ, MinIO, a separate worker
container, Kubernetes, or microservices as mandatory dependencies. Adapters for those
may exist later but can never become requirements. If a feature seems to need another
mandatory service, redesign it.

## Messaging reliability

Messages must be persisted before realtime broadcast. WebSocket is transport, not
source of truth. Design for reconnect/replay using sequence IDs (or another
deterministic mechanism). Agent-to-agent runs must carry `rootRunId`, `causationId`,
`hopCount`. Default maximum hop count: 4. Must prevent infinite agent loops.

## Memory

v0.1 memory uses recent message history, rolling conversation summaries, and explicit
long-term `MemoryFact`s. MemoryFacts must be inspectable, editable, deletable, and
deduplicated. A vector database must not be mandatory.

## Providers

Provider abstraction must represent:
- Remote: Anthropic API, OpenAI API, OpenRouter, DeepSeek, OpenAI-compatible APIs.
- Local/agentd-backed: Claude Subscription, Ollama, other future local providers.

Claude Subscription must be treated as a user-owned local provider surfaced through
agentd — never implemented by sharing/proxying one user's subscription to unrelated
users.

## agentd contract

agentd is NOT a remote shell; the server must never send arbitrary shell commands.
Server requests are high-level operations: `runtime.run`, `runtime.resume`,
`provider.chat`, `provider.models`, `workspace.list`, `approval.respond`. The agentd
implementation belongs to Developer B; Developer A owns the protocol/contract used to
talk to it and should keep new fields/events minimal and stable.

## Shared contract ownership

Developer A is primary owner of `repos/protocol` and `repos/sdk`. Contracts must stay
vendor-neutral, be versioned carefully, avoid leaking implementation-specific
concepts, and document request/response/event shapes.

## Testing minimums

Server boots; database initializes; first admin flow; agent creation; DM creation;
group creation; message persistence; WebSocket delivery; reconnect/replay; agent
invocation; max-hop protection; provider failure handling; memory persistence;
runtime binding persistence. Untested work must not be reported as completed.

## Plan sequencing (this charter is implemented across multiple plan docs)

1. `2026-09-13-protocol-foundations.md` — vendor-neutral schemas in `repos/protocol`
   (Agent, RuntimeBinding/Session, Conversation, Message, Provider, agentd operation
   envelope, MemoryFact, WebSocket envelope, Approval). Everything else depends on this.
2. `2026-09-13-server-foundations.md` — `repos/server` boot, SQLite+WAL persistence,
   migrations, auth (first-admin/login/sessions), permissions skeleton, Agent CRUD,
   WebSocket hub with persist-before-broadcast + sequence-based reconnect/replay.
3. *(planned next, not yet written)* `server-messaging-core` — conversations
   (DM/group), messages, mentions, replies, membership management, wired onto the
   WS hub's topic/replay mechanism from plan 2. Carries forward from plan 2's
   final review (all deferred as non-blocking at the time, now load-bearing once
   this plan adds real traffic): session tokens are stored plaintext and passed
   in the `/ws` query string (hash at rest once revocation/logout exists);
   `ConnectionHub.subscribe()` replaces rather than merges a socket's topic set,
   and no caller besides `/ws` itself wires socket-close → unsubscribe; the
   `/ws` route's replay-then-subscribe ordering is only race-free because the
   handler is fully synchronous today — the moment any `await` is added before
   `hub.subscribe()`, a live event could be delivered ahead of the replayed
   backlog (needs a seq high-water-mark guard or an explicit ordering comment);
   `event_log` has no retention/pruning; there is no production request/error
   logging (`Fastify({ logger: false })` hardcoded) so failures are invisible
   in a real deployment; `dist/` ships compiled `*.test.js` files (tsconfig
   needs the same test-exclude the protocol plan already added for itself).
4. *(planned next)* `server-runtime-and-agent-to-agent` — RuntimeSession/RuntimeBinding
   persistence, Native Agent runtime loop, agent-to-agent messaging with
   rootRunId/causationId/hopCount and max-hop enforcement, approvals.
   Carries forward from `server-messaging-core`'s final review: `GET
   /api/conversations/:id/messages` returns 403 (not 404) for a nonexistent
   conversation, inconsistent with POST's 404 (not a security issue, UUIDs
   unguessable, just API-consistency polish); `removeParticipant` ignores
   `participant_type` despite the composite PK including it — safe today
   given `randomUUID()` collision odds, but becomes a latent trap once
   agents are real conversation participants this plan will add; message
   persistence and `event_log` insertion are two separate transactions, so a
   crash between them could leave a persisted message with no replayable
   event — a true transactional outbox is overkill for v0.1 but worth
   recording as a durability seam; a newly-added group member replays the
   conversation's entire pre-join history on reconnect (implicit product
   decision — "new members see full history" — never explicitly stated);
   `isParticipant(..., 'user')` is hardcoded at both message route call
   sites and will need revisiting the moment agents can post messages.
   Also carries a documented (not code-enforced) policy: any admin/owner
   can add themselves to any group conversation and read its full history —
   this is intentional under the charter's single-workspace, trusted-admin
   self-host model (same trust level as agent listing and auth already
   assume), not an oversight. Revisit only if a multi-tenant or
   least-privilege admin model is ever needed.
5. *(planned next)* `server-providers` — provider abstraction, Anthropic/OpenAI/
   OpenRouter/DeepSeek/OpenAI-compatible clients, agentd-backed Claude
   Subscription/Ollama contract, provider.chat/provider.models, failure handling.
   Slots into `runAgentTurn`'s `RespondFn` seam (`repos/server/src/runtime/engine.ts`)
   without touching that plan's persistence/orchestration code. Carries forward
   from `server-runtime-and-agent-to-agent`'s final review: once a real
   `RespondFn` can name a `handoffToAgentId` that doesn't correspond to a real
   agent (today's `defaultRespond` stub never does), `runAgentTurn` needs to
   validate the handoff target before dispatching rather than letting the
   agent_runs FK constraint throw mid-chain after earlier hops in the same
   chain have already persisted messages and broadcast them over WS — a
   partial-chain failure surfaced as a 500 after real side effects occurred.
   Also: the recursive handoff chain runs synchronously inside one HTTP
   request, so a capped chain becomes up to 5 sequential provider calls in
   one request — the hop cap bounds depth, not latency or cost; a wall-clock
   or token budget belongs alongside it once real (non-stub) providers land.
   `vendorState` on `RuntimeBinding` is not yet reachable over REST
   (`POST /api/runtime-bindings` omits it from its body schema) — add it
   when a runtime actually needs to write vendor session state.
   `POST /api/runtime-sessions` checks that the caller owns `agentId` but
   never cross-validates that `runtimeBindingId` actually belongs to that
   same agent — a user could pair their own agent with a runtime binding
   that belongs to a different agent (theirs or, once multi-user ownership
   models exist, someone else's). Add that consistency check.
6. *(planned next)* `server-memory-and-jobs` — MemoryFact CRUD + dedup, rolling
   conversation summaries, built-in background job runner. Carries forward
   from `server-providers`'s final review: `resolveProviderClient` throws a
   plain `Error` (not `ProviderError`) for a provider config missing
   `apiKey`/`baseUrl` at resolution time — REST creation now rejects such
   configs with 400 up front, but a pre-existing or directly-DB-mutated
   config could still reach this path and crash a `RespondFn` call outside
   `instanceof ProviderError` handling; worth hardening if config mutation
   ever gets a REST update endpoint. `createProviderRespond`'s
   `toChatMessages` never emits a system-role message, so an agent's
   `personality` field never reaches any provider today — a real product
   gap, not a bug, to close when personality/system-prompt composition is
   designed. `GET /api/providers` and `GET /api/providers/:id/models` are
   `requireAuth`-only (not `provider:manage`-gated), letting any authenticated
   member enumerate configured provider kinds/ids and trigger an outbound
   `listModels()` call spending the configured API key — intentional under
   the charter's trusted-single-workspace admin model (same trust level as
   agent listing), revisit only alongside a multi-tenant/least-privilege
   redesign. Provider API keys are stored plaintext in `provider_configs`,
   consistent with the plaintext-session-token precedent already carried
   from `server-messaging-core` — both should be addressed together if/when
   at-rest encryption is prioritized.
7. *(planned next)* `sdk-client` — `repos/sdk` REST/WS client wrapping
   `repos/protocol` types, versioned against the server API from plans 2-6.
   Carries forward from `server-memory-and-jobs`'s final review: nothing
   outside `src/memory/` yet reads a `MemoryFact` or `ConversationSummary`
   into an agent turn — `runAgentTurn` still builds context from recent
   messages alone. The memory triad (recent messages, rolling summaries,
   explicit facts) is now persisted and inspectable but not yet consumed;
   a future plan needs to wire memory retrieval into the `RespondFn`/
   runtime path for it to actually shape what an agent says. Also:
   `defaultSummarize` re-appends the same last-20 messages on every
   regeneration instead of using the persisted `upToMessageId` to select
   only newer messages — not truly incremental, and duplicate content only
   stays hidden by the 2000-char tail slice. Harmless as a deterministic
   placeholder, but this is what production `index.ts` runs today — flag
   it prominently for whoever writes the first real (non-placeholder)
   `SummarizeFn`, since incrementally-wrong summaries compound quietly.
   Smaller items: the `jobs` table has no pruning/retention (same class as
   `event_log`'s already-carried retention gap); `failJob` has no retry/
   backoff despite `attempts`/`run_at` columns existing for it — a
   transient failure only heals via the next natural re-enqueue; `PATCH
   .../memory-facts/:factId` on merge-on-collision returns 200 with a
   DIFFERENT id than the URL addressed (correct repository behavior, but
   an undocumented REST-level surprise worth a response-shape note if this
   endpoint gets an SDK wrapper).
8. *(planned next)* `cloud-foundations` — minimal `repos/cloud` control-plane
   scaffold, scoped to what a managed offering needs without violating the
   self-host/Claude-Subscription invariants above.

Each plan is independently testable and does not block the others from being
authored; only genuine data/type dependencies (e.g. plan 2 depends on plan 1's
protocol package) impose ordering.
