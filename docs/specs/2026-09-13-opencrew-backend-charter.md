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
5. *(planned next)* `server-providers` — provider abstraction, Anthropic/OpenAI/
   OpenRouter/DeepSeek/OpenAI-compatible clients, agentd-backed Claude
   Subscription/Ollama contract, provider.chat/provider.models, failure handling.
6. *(planned next)* `server-memory-and-jobs` — MemoryFact CRUD + dedup, rolling
   conversation summaries, built-in background job runner.
7. *(planned next)* `sdk-client` — `repos/sdk` REST/WS client wrapping
   `repos/protocol` types, versioned against the server API from plans 2-6.
8. *(planned next)* `cloud-foundations` — minimal `repos/cloud` control-plane
   scaffold, scoped to what a managed offering needs without violating the
   self-host/Claude-Subscription invariants above.

Each plan is independently testable and does not block the others from being
authored; only genuine data/type dependencies (e.g. plan 2 depends on plan 1's
protocol package) impose ordering.
