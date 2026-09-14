# Server Memory & Jobs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `@opencrew/server` v0.1's memory layer — recent message history (fixed to actually be recent), rolling per-conversation summaries, and explicit long-term `MemoryFact`s — backed by a lightweight, self-hosted, SQLite-only background job runner.

**Architecture:** Three additive pieces on top of the existing messaging/runtime foundation. (1) A generic, SQLite-backed `JobRunner` (`src/jobs/`) — no Redis/BullMQ/cron daemon, just a polling loop over a `jobs` table with a `runOnce()` seam so tests never depend on real timers. (2) `MemoryFact` CRUD with dedup-by-normalized-content (`src/memory/repository.ts`), REST-exposed and scoped to the owning agent's owner (or an admin/owner-role user, matching this codebase's existing "admin/owner is a site-wide trusted role" convention). (3) Rolling `ConversationSummary` regeneration (`src/memory/summary.ts`) behind a `SummarizeFn` seam — mirrors `RespondFn`'s injectable-default pattern — triggered as a background job every time a message is posted (deduped so a burst of messages collapses into one pending job), fetched over REST. Along the way, this plan fixes a real bug found while grounding it: `runAgentTurn`'s `recentMessages` was built from the OLDEST messages in a conversation, not the most recent — silently wrong context for any conversation past its first 20 messages.

**Tech Stack:** Node 20+, TypeScript 5 (strict), Fastify 5, better-sqlite3 (WAL), Zod 3, Vitest 2 — same stack as every prior plan in this repo.

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- Self-host default stays lightweight: one server process, SQLite + WAL, no mandatory Postgres/Redis/Kafka/etc. The job runner is an in-process `setInterval` polling loop backed by a SQLite table — never a new mandatory service.
- A vector database must not be mandatory. `MemoryFact` dedup uses normalized-string equality (trim + lowercase), not embeddings.
- `MemoryFact`s must be inspectable, editable, deletable, and deduplicated (charter, "Memory" section) — all four are testing minimums for this plan.
- Testing minimum from the charter: "memory persistence" must be covered by a real test, not asserted-but-untested.
- TypeScript strict mode. `npx tsc -p tsconfig.json --noEmit` (checks test files too, this repo's tsconfig split) must stay clean alongside `npm test`.
- Every new table's id is `TEXT PRIMARY KEY` via `randomUUID()`, following every table in this repo except the deliberate exception (`provider_configs`, caller-supplied id) — none of this plan's tables are that exception.
- Every `ORDER BY created_at` in a new query must add `, rowid ASC` (or `DESC`) as a tiebreaker — `created_at` alone does not preserve insertion order for same-millisecond writes with UUID ids. Two real bugs from omitting this were found and fixed in earlier plans (`messages`, `agent_runs`).
- No real network calls in any test. This plan doesn't add a network-calling client, but `SummarizeFn`'s default implementation must be a pure, deterministic function — never invoke a provider client from `defaultSummarize`.
- Migrations are plain `.sql` files under `src/db/migrations/`, applied in filename-sorted order, tracked in a `schema_migrations` table (`src/db/migrate.ts`, already exists — do not modify it). The next unused migration number is `0012` (`0011_provider_configs.sql` is the last one that exists).
- `npm run build` (`tsc -p tsconfig.build.json && node scripts/copy-migrations.mjs`) must produce a `dist/` with no `*.test.js` files and every migration `.sql` file present — verify this in the final task.

---

### Task 1: Fix `recentMessages` to actually mean "recent"

**Files:**
- Modify: `src/messages/repository.ts` (add a new function; do not change `listMessagesForConversation`, which the REST route at `GET /api/conversations/:id/messages` correctly uses for oldest-first pagination — that behavior is intentional and tested, leave it alone)
- Modify: `src/runtime/engine.ts:4,66` (swap which function builds `recentMessages`)
- Test: `src/messages/repository.test.ts`

**Context:** `src/runtime/engine.ts:66` calls `listMessagesForConversation(deps.db, input.conversationId, 20)` to build the `recentMessages` array passed to every `RespondFn` call — this is meant to be "what has this conversation said recently" context for whatever generates the agent's next reply. But `listMessagesForConversation` (`src/messages/repository.ts:88-93`) is `ORDER BY created_at ASC, rowid ASC LIMIT ?` — for any conversation with more than `limit` messages, this returns the OLDEST messages, not the most recent ones. An agent in a long-running conversation would always see the same stale opening messages as its "recent" context, never the actual latest turns. This is confirmed intentional-but-wrong: `src/messages/repository.test.ts`'s existing test `'orders messages oldest-first and respects the limit'` (around line 151) locks in this behavior for the REST pagination use case, which is a legitimate, different need (paging through history from the start) — so the fix is a new function for the runtime's use case, not a change to the existing one.

**Interfaces:**
- Produces: `listRecentMessagesForConversation(db: Database.Database, conversationId: string, limit?: number): Message[]` — returns up to `limit` messages, the MOST RECENT ones, in ascending chronological order (oldest-of-the-recent-batch first, matching what a chat-completion API expects as message history order).
- Consumes (Task 5, 6, 7 later in this plan use this too): same signature, for building the message window a conversation summary regenerates from.

- [ ] **Step 1: Write the failing test**

Add to `src/messages/repository.test.ts`, inside the `describe('messages repository', ...)` block, after the existing `'orders messages oldest-first and respects the limit'` test. First add `listRecentMessagesForConversation` to the existing import on line 9:

```ts
import { createMessage, listMessagesForConversation, listRecentMessagesForConversation, ReplyNotInConversationError } from './repository.js';
```

Then add the new test:

```ts
  it('listRecentMessagesForConversation returns the most recent N messages, oldest-of-the-batch first', () => {
    const { db, alice, conversation } = freshDbWithConversation();
    for (const body of ['one', 'two', 'three', 'four']) {
      createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body, mentions: [], replyToMessageId: null });
    }
    const recent = listRecentMessagesForConversation(db, conversation.id, 2);
    expect(recent).toHaveLength(2);
    expect(recent[0].body).toBe('three');
    expect(recent[1].body).toBe('four');
    db.close();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/messages/repository.test.ts`
Expected: FAIL — `listRecentMessagesForConversation is not a function` (or a TypeScript error if you run `tsc` first; either failure mode confirms the function doesn't exist yet).

- [ ] **Step 3: Write the minimal implementation**

Add to `src/messages/repository.ts`, after the existing `listMessagesForConversation` function (end of file):

```ts
export function listRecentMessagesForConversation(db: Database.Database, conversationId: string, limit = 20): Message[] {
  const rows = db
    .prepare('SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?')
    .all(conversationId, limit) as MessageRow[];
  return rows.reverse().map((row) => rowToMessage(row, getMentions(db, row.id)));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/messages/repository.test.ts`
Expected: PASS (all tests in the file, including the new one).

- [ ] **Step 5: Switch the runtime engine to use the fixed function**

In `src/runtime/engine.ts`, change line 4:

```ts
import { createMessage, listRecentMessagesForConversation } from '../messages/repository.js';
```

And change line 66:

```ts
  const recentMessages = listRecentMessagesForConversation(deps.db, input.conversationId, 20);
```

- [ ] **Step 6: Run the full suite to confirm no regression**

Run: `npm test`
Expected: PASS — 125 tests (the existing suite; `src/runtime/engine.test.ts`'s assertions on `recentMessages` only check a single-message conversation, so they pass unchanged with either function).

Also run: `npx tsc -p tsconfig.json --noEmit`
Expected: clean, no errors.

- [ ] **Step 7: Commit**

```bash
git add src/messages/repository.ts src/messages/repository.test.ts src/runtime/engine.ts
git commit -m "fix: build agent turn context from the most recent messages, not the oldest"
```

---

### Task 2: Background job runner core

**Files:**
- Create: `src/db/migrations/0012_jobs.sql`
- Create: `src/jobs/repository.ts`
- Test: `src/jobs/repository.test.ts`
- Create: `src/jobs/runner.ts`
- Test: `src/jobs/runner.test.ts`

**Context:** This is the generic, reusable scheduling primitive the rest of this plan builds on (conversation-summary regeneration is its first consumer). Keep it domain-agnostic — nothing in this task should know about messages, conversations, or memory. A job is: a `type` string, a JSON `payload`, a `status`, a `run_at` time, and an optional `dedupe_key` that collapses repeated pending enqueues of the same logical work into one row (e.g. ten messages posted in quick succession to the same conversation should produce one pending "regenerate this conversation's summary" job, not ten). Once a job moves to `running`, a fresh enqueue with the same dedupe key is allowed again — this is intentional: it guarantees a burst of activity that arrives *while* a job is already executing still gets picked up by a follow-up job, rather than being silently dropped.

**Interfaces:**
- Produces: `JobRecord { id: string; type: string; payload: unknown; status: 'pending' | 'running' | 'done' | 'failed'; attempts: number; lastError: string | null; runAt: string; createdAt: string; updatedAt: string }`
- Produces: `enqueueJob(db: Database.Database, input: { type: string; payload: unknown; dedupeKey?: string; runAt?: string }): void`
- Produces: `claimNextJob(db: Database.Database, now?: string): JobRecord | undefined`
- Produces: `completeJob(db: Database.Database, id: string): void`
- Produces: `failJob(db: Database.Database, id: string, error: string): void`
- Produces: `JobHandler = (db: Database.Database, payload: unknown) => Promise<void>`
- Produces: `class JobRunner { constructor(db, handlers: Record<string, JobHandler>, intervalMs?: number); runOnce(): Promise<boolean>; start(): void; stop(): void }`
- Consumes (later tasks in this plan): `enqueueJob`, `JobRunner`.

- [ ] **Step 1: Write the migration**

Create `src/db/migrations/0012_jobs.sql`:

```sql
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'done', 'failed')) DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  dedupe_key TEXT,
  run_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_jobs_status_run_at ON jobs (status, run_at);

CREATE UNIQUE INDEX idx_jobs_pending_dedupe ON jobs (dedupe_key) WHERE status = 'pending';
```

- [ ] **Step 2: Write the failing repository test**

Create `src/jobs/repository.test.ts`:

```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { runMigrations } from '../db/migrate.js';
import { claimNextJob, completeJob, enqueueJob, failJob } from './repository.js';

describe('jobs repository', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  it('enqueues and claims a due job', () => {
    enqueueJob(db, { type: 'noop', payload: { x: 1 } });
    const claimed = claimNextJob(db);
    expect(claimed?.type).toBe('noop');
    expect(claimed?.status).toBe('running');
    expect(claimed?.payload).toEqual({ x: 1 });
  });

  it('does not claim a job scheduled in the future', () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    enqueueJob(db, { type: 'noop', payload: {}, runAt: future });
    expect(claimNextJob(db)).toBeUndefined();
  });

  it('collapses duplicate pending enqueues sharing a dedupeKey', () => {
    enqueueJob(db, { type: 'summarize', payload: { conversationId: 'c1' }, dedupeKey: 'summarize:c1' });
    enqueueJob(db, { type: 'summarize', payload: { conversationId: 'c1' }, dedupeKey: 'summarize:c1' });
    const row = db.prepare("SELECT COUNT(*) as n FROM jobs WHERE status = 'pending'").get() as { n: number };
    expect(row.n).toBe(1);
  });

  it('allows a fresh enqueue with the same dedupeKey once the prior job is running', () => {
    enqueueJob(db, { type: 'summarize', payload: { conversationId: 'c1' }, dedupeKey: 'summarize:c1' });
    claimNextJob(db);
    enqueueJob(db, { type: 'summarize', payload: { conversationId: 'c1' }, dedupeKey: 'summarize:c1' });
    const row = db.prepare("SELECT COUNT(*) as n FROM jobs WHERE status = 'pending'").get() as { n: number };
    expect(row.n).toBe(1);
  });

  it('completeJob marks a job done', () => {
    enqueueJob(db, { type: 'noop', payload: {} });
    const claimed = claimNextJob(db)!;
    completeJob(db, claimed.id);
    const row = db.prepare('SELECT status FROM jobs WHERE id = ?').get(claimed.id) as { status: string };
    expect(row.status).toBe('done');
  });

  it('failJob marks a job failed, records the error, and increments attempts', () => {
    enqueueJob(db, { type: 'noop', payload: {} });
    const claimed = claimNextJob(db)!;
    failJob(db, claimed.id, 'boom');
    const row = db.prepare('SELECT status, attempts, last_error FROM jobs WHERE id = ?').get(claimed.id) as {
      status: string;
      attempts: number;
      last_error: string;
    };
    expect(row.status).toBe('failed');
    expect(row.attempts).toBe(1);
    expect(row.last_error).toBe('boom');
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run src/jobs/repository.test.ts`
Expected: FAIL — `src/jobs/repository.ts` doesn't exist yet.

- [ ] **Step 4: Write the minimal implementation**

Create `src/jobs/repository.ts`:

```ts
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

export interface JobRecord {
  id: string;
  type: string;
  payload: unknown;
  status: 'pending' | 'running' | 'done' | 'failed';
  attempts: number;
  lastError: string | null;
  runAt: string;
  createdAt: string;
  updatedAt: string;
}

interface JobRow {
  id: string;
  type: string;
  payload: string;
  status: 'pending' | 'running' | 'done' | 'failed';
  attempts: number;
  last_error: string | null;
  run_at: string;
  created_at: string;
  updated_at: string;
}

function rowToJob(row: JobRow): JobRecord {
  return {
    id: row.id,
    type: row.type,
    payload: JSON.parse(row.payload),
    status: row.status,
    attempts: row.attempts,
    lastError: row.last_error,
    runAt: row.run_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function enqueueJob(
  db: Database.Database,
  input: { type: string; payload: unknown; dedupeKey?: string; runAt?: string }
): void {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT OR IGNORE INTO jobs (id, type, payload, status, attempts, last_error, dedupe_key, run_at, created_at, updated_at)
     VALUES (?, ?, ?, 'pending', 0, NULL, ?, ?, ?, ?)`
  ).run(randomUUID(), input.type, JSON.stringify(input.payload), input.dedupeKey ?? null, input.runAt ?? now, now, now);
}

export function claimNextJob(db: Database.Database, now: string = new Date().toISOString()): JobRecord | undefined {
  const claim = db.transaction((claimNow: string) => {
    const row = db
      .prepare(`SELECT * FROM jobs WHERE status = 'pending' AND run_at <= ? ORDER BY run_at ASC, rowid ASC LIMIT 1`)
      .get(claimNow) as JobRow | undefined;
    if (!row) return undefined;
    db.prepare(`UPDATE jobs SET status = 'running', updated_at = ? WHERE id = ? AND status = 'pending'`).run(claimNow, row.id);
    return rowToJob({ ...row, status: 'running', updated_at: claimNow });
  });
  return claim(now);
}

export function completeJob(db: Database.Database, id: string): void {
  db.prepare(`UPDATE jobs SET status = 'done', updated_at = ? WHERE id = ?`).run(new Date().toISOString(), id);
}

export function failJob(db: Database.Database, id: string, error: string): void {
  const now = new Date().toISOString();
  db.prepare(`UPDATE jobs SET status = 'failed', attempts = attempts + 1, last_error = ?, updated_at = ? WHERE id = ?`).run(
    error,
    now,
    id
  );
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/jobs/repository.test.ts`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Write the failing runner test**

Create `src/jobs/runner.test.ts`:

```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { runMigrations } from '../db/migrate.js';
import { enqueueJob } from './repository.js';
import { JobRunner } from './runner.js';

describe('JobRunner', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  it('runOnce executes a due job with its registered handler and marks it done', async () => {
    const handler = vi.fn(async () => {});
    const runner = new JobRunner(db, { greet: handler });
    enqueueJob(db, { type: 'greet', payload: { name: 'world' } });

    const ran = await runner.runOnce();

    expect(ran).toBe(true);
    expect(handler).toHaveBeenCalledWith(db, { name: 'world' });
    const row = db.prepare("SELECT status FROM jobs WHERE type = 'greet'").get() as { status: string };
    expect(row.status).toBe('done');
  });

  it('runOnce returns false when no job is due', async () => {
    const runner = new JobRunner(db, {});
    expect(await runner.runOnce()).toBe(false);
  });

  it('runOnce marks a job failed when its handler throws, without crashing', async () => {
    const runner = new JobRunner(db, {
      boom: async () => {
        throw new Error('handler exploded');
      },
    });
    enqueueJob(db, { type: 'boom', payload: {} });

    await expect(runner.runOnce()).resolves.toBe(true);
    const row = db.prepare("SELECT status, last_error FROM jobs WHERE type = 'boom'").get() as {
      status: string;
      last_error: string;
    };
    expect(row.status).toBe('failed');
    expect(row.last_error).toBe('handler exploded');
  });

  it('runOnce marks a job failed when no handler is registered for its type', async () => {
    const runner = new JobRunner(db, {});
    enqueueJob(db, { type: 'unknown-type', payload: {} });

    await runner.runOnce();
    const row = db.prepare("SELECT status, last_error FROM jobs WHERE type = 'unknown-type'").get() as {
      status: string;
      last_error: string;
    };
    expect(row.status).toBe('failed');
    expect(row.last_error).toContain('no handler registered');
  });
});
```

- [ ] **Step 7: Run test to verify it fails**

Run: `npx vitest run src/jobs/runner.test.ts`
Expected: FAIL — `src/jobs/runner.ts` doesn't exist yet.

- [ ] **Step 8: Write the minimal implementation**

Create `src/jobs/runner.ts`:

```ts
import type Database from 'better-sqlite3';
import { claimNextJob, completeJob, failJob } from './repository.js';

export type JobHandler = (db: Database.Database, payload: unknown) => Promise<void>;

export class JobRunner {
  private timer: NodeJS.Timeout | undefined;

  constructor(
    private db: Database.Database,
    private handlers: Record<string, JobHandler>,
    private intervalMs = 5000
  ) {}

  async runOnce(): Promise<boolean> {
    const job = claimNextJob(this.db);
    if (!job) return false;
    const handler = this.handlers[job.type];
    if (!handler) {
      failJob(this.db, job.id, `no handler registered for job type "${job.type}"`);
      return true;
    }
    try {
      await handler(this.db, job.payload);
      completeJob(this.db, job.id);
    } catch (err) {
      failJob(this.db, job.id, (err as Error).message);
    }
    return true;
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.runOnce().catch(() => {});
    }, this.intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `npx vitest run src/jobs/runner.test.ts`
Expected: PASS (all 4 tests).

- [ ] **Step 10: Run the full suite and typecheck**

Run: `npm test && npx tsc -p tsconfig.json --noEmit`
Expected: both clean.

- [ ] **Step 11: Commit**

```bash
git add src/db/migrations/0012_jobs.sql src/jobs/repository.ts src/jobs/repository.test.ts src/jobs/runner.ts src/jobs/runner.test.ts
git commit -m "feat: add a SQLite-backed background job runner"
```

---

### Task 3: MemoryFact repository with dedup

**Files:**
- Create: `src/db/migrations/0013_memory_facts.sql`
- Create: `src/memory/repository.ts`
- Test: `src/memory/repository.test.ts`

**Context:** Uses the `MemoryFact` schema already defined in `@opencrew/protocol` (`repos/protocol/src/schemas/memory.ts`, already exported from the package root) — do not redefine it. Dedup key: `content.trim().toLowerCase()`, stored in a `content_key` column with a `UNIQUE(agent_id, content_key)` index, so two facts with the same content (modulo whitespace/case) for the same agent can never both exist. `createMemoryFact` reports whether it created a new row or matched an existing one, so the REST layer (Task 4) can return 201 vs 200 correctly. `updateMemoryFact` applies the same dedup rule on edit: if editing a fact's content makes it collide with a *different* existing fact for the same agent, the edited row is deleted and the pre-existing colliding fact is returned instead — same merge-on-collision semantics as create, applied consistently.

**Interfaces:**
- Consumes: `MemoryFactSchema`, `type MemoryFact` from `@opencrew/protocol`.
- Produces: `createMemoryFact(db, input: { agentId: string; content: string; source: 'conversation' | 'manual' | 'summary'; tags?: string[] }): { fact: MemoryFact; created: boolean }`
- Produces: `listMemoryFactsForAgent(db, agentId: string): MemoryFact[]`
- Produces: `getMemoryFact(db, id: string): MemoryFact | undefined`
- Produces: `updateMemoryFact(db, id: string, input: { content?: string; tags?: string[] }): MemoryFact | undefined`
- Produces: `deleteMemoryFact(db, id: string): void`
- Consumes (later, Task 4): all five functions above.

- [ ] **Step 1: Write the migration**

Create `src/db/migrations/0013_memory_facts.sql`:

```sql
CREATE TABLE memory_facts (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  content TEXT NOT NULL,
  content_key TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('conversation', 'manual', 'summary')),
  tags TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_memory_facts_agent_content_key ON memory_facts (agent_id, content_key);
CREATE INDEX idx_memory_facts_agent_created ON memory_facts (agent_id, created_at);
```

- [ ] **Step 2: Write the failing test**

Create `src/memory/repository.test.ts`:

```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createMemoryFact, deleteMemoryFact, getMemoryFact, listMemoryFactsForAgent, updateMemoryFact } from './repository.js';

describe('memory facts repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithAgent() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-memory-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Researcher',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    return { db, owner, agent };
  }

  it('creates a memory fact that round-trips through the shared protocol schema', () => {
    const { db, agent } = freshDbWithAgent();
    const { fact, created } = createMemoryFact(db, { agentId: agent.id, content: 'Prefers concise answers.', source: 'manual' });
    expect(created).toBe(true);
    expect(fact.content).toBe('Prefers concise answers.');
    expect(fact.tags).toEqual([]);
    expect(getMemoryFact(db, fact.id)?.id).toBe(fact.id);
    db.close();
  });

  it('deduplicates by normalized content per agent instead of creating a second row', () => {
    const { db, agent } = freshDbWithAgent();
    const first = createMemoryFact(db, { agentId: agent.id, content: 'Likes dark mode.', source: 'manual' });
    const second = createMemoryFact(db, { agentId: agent.id, content: '  LIKES dark mode.  ', source: 'conversation' });
    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(second.fact.id).toBe(first.fact.id);
    expect(listMemoryFactsForAgent(db, agent.id)).toHaveLength(1);
    db.close();
  });

  it('lets the same content be stored separately per distinct agent', () => {
    const { db, owner, agent } = freshDbWithAgent();
    const otherAgent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Second',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    createMemoryFact(db, { agentId: agent.id, content: 'Shared fact.', source: 'manual' });
    const second = createMemoryFact(db, { agentId: otherAgent.id, content: 'Shared fact.', source: 'manual' });
    expect(second.created).toBe(true);
    db.close();
  });

  it('updates content and tags, refreshing the dedup key', () => {
    const { db, agent } = freshDbWithAgent();
    const { fact } = createMemoryFact(db, { agentId: agent.id, content: 'Original.', source: 'manual', tags: ['a'] });
    const updated = updateMemoryFact(db, fact.id, { content: 'Revised.', tags: ['a', 'b'] });
    expect(updated?.content).toBe('Revised.');
    expect(updated?.tags).toEqual(['a', 'b']);
    db.close();
  });

  it('merges an update into an existing fact when the new content collides with it', () => {
    const { db, agent } = freshDbWithAgent();
    const { fact: keep } = createMemoryFact(db, { agentId: agent.id, content: 'Keep me.', source: 'manual' });
    const { fact: editMe } = createMemoryFact(db, { agentId: agent.id, content: 'Edit me.', source: 'manual' });

    const result = updateMemoryFact(db, editMe.id, { content: 'Keep me.' });

    expect(result?.id).toBe(keep.id);
    expect(getMemoryFact(db, editMe.id)).toBeUndefined();
    expect(listMemoryFactsForAgent(db, agent.id)).toHaveLength(1);
    db.close();
  });

  it('deletes a memory fact', () => {
    const { db, agent } = freshDbWithAgent();
    const { fact } = createMemoryFact(db, { agentId: agent.id, content: 'Temporary.', source: 'manual' });
    deleteMemoryFact(db, fact.id);
    expect(getMemoryFact(db, fact.id)).toBeUndefined();
    db.close();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run src/memory/repository.test.ts`
Expected: FAIL — `src/memory/repository.ts` doesn't exist yet.

- [ ] **Step 4: Write the minimal implementation**

Create `src/memory/repository.ts`:

```ts
import { MemoryFactSchema, type MemoryFact } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface MemoryFactRow {
  id: string;
  agent_id: string;
  content: string;
  content_key: string;
  source: 'conversation' | 'manual' | 'summary';
  tags: string;
  created_at: string;
  updated_at: string;
}

function normalize(content: string): string {
  return content.trim().toLowerCase();
}

function rowToMemoryFact(row: MemoryFactRow): MemoryFact {
  return MemoryFactSchema.parse({
    id: row.id,
    agentId: row.agent_id,
    content: row.content,
    source: row.source,
    tags: JSON.parse(row.tags),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

export function createMemoryFact(
  db: Database.Database,
  input: { agentId: string; content: string; source: 'conversation' | 'manual' | 'summary'; tags?: string[] }
): { fact: MemoryFact; created: boolean } {
  const now = new Date().toISOString();
  const contentKey = normalize(input.content);
  const row = {
    id: randomUUID(),
    agent_id: input.agentId,
    content: input.content,
    content_key: contentKey,
    source: input.source,
    tags: JSON.stringify(input.tags ?? []),
    created_at: now,
    updated_at: now,
  };
  const result = db
    .prepare(
      `INSERT OR IGNORE INTO memory_facts (id, agent_id, content, content_key, source, tags, created_at, updated_at)
       VALUES (@id, @agent_id, @content, @content_key, @source, @tags, @created_at, @updated_at)`
    )
    .run(row);
  const created = result.changes === 1;
  const existing = db
    .prepare('SELECT * FROM memory_facts WHERE agent_id = ? AND content_key = ?')
    .get(input.agentId, contentKey) as MemoryFactRow;
  return { fact: rowToMemoryFact(existing), created };
}

export function listMemoryFactsForAgent(db: Database.Database, agentId: string): MemoryFact[] {
  const rows = db
    .prepare('SELECT * FROM memory_facts WHERE agent_id = ? ORDER BY created_at ASC, rowid ASC')
    .all(agentId) as MemoryFactRow[];
  return rows.map(rowToMemoryFact);
}

export function getMemoryFact(db: Database.Database, id: string): MemoryFact | undefined {
  const row = db.prepare('SELECT * FROM memory_facts WHERE id = ?').get(id) as MemoryFactRow | undefined;
  return row ? rowToMemoryFact(row) : undefined;
}

export function updateMemoryFact(
  db: Database.Database,
  id: string,
  input: { content?: string; tags?: string[] }
): MemoryFact | undefined {
  const existing = db.prepare('SELECT * FROM memory_facts WHERE id = ?').get(id) as MemoryFactRow | undefined;
  if (!existing) return undefined;

  const now = new Date().toISOString();
  const content = input.content ?? existing.content;
  const contentKey = normalize(content);
  const tags = input.tags ?? (JSON.parse(existing.tags) as string[]);

  if (contentKey !== existing.content_key) {
    const collision = db
      .prepare('SELECT * FROM memory_facts WHERE agent_id = ? AND content_key = ? AND id != ?')
      .get(existing.agent_id, contentKey, id) as MemoryFactRow | undefined;
    if (collision) {
      db.prepare('DELETE FROM memory_facts WHERE id = ?').run(id);
      return rowToMemoryFact(collision);
    }
  }

  db.prepare(`UPDATE memory_facts SET content = ?, content_key = ?, tags = ?, updated_at = ? WHERE id = ?`).run(
    content,
    contentKey,
    JSON.stringify(tags),
    now,
    id
  );
  return getMemoryFact(db, id);
}

export function deleteMemoryFact(db: Database.Database, id: string): void {
  db.prepare('DELETE FROM memory_facts WHERE id = ?').run(id);
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/memory/repository.test.ts`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Run the full suite and typecheck**

Run: `npm test && npx tsc -p tsconfig.json --noEmit`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add src/db/migrations/0013_memory_facts.sql src/memory/repository.ts src/memory/repository.test.ts
git commit -m "feat: add MemoryFact repository with per-agent content dedup"
```

---

### Task 4: MemoryFact REST routes

**Files:**
- Create: `src/memory/routes.ts` (exports `registerMemoryFactRoutes`; a second export, `registerConversationSummaryRoutes`, is added to this same file in Task 6 — leave room, don't split into a separate file)
- Modify: `src/app.ts` (register the new routes)
- Test: `src/memory/routes.test.ts`

**Context:** `MemoryFact`s belong to an agent. Access control follows the same convention already established in `src/conversations/routes.ts` (see its comments at lines 112 and 142): "admin/owner is a site-wide trusted role in this self-host model" — so a `MemoryFact` route is accessible to the agent's owning user OR any `admin`/`owner`-role user, not gated by a new `permissions/model.ts` action (agents have no per-action permission today beyond ownership; `src/agents/routes.ts` only scopes by `ownerUserId`, it doesn't touch `permissions/model.ts` at all — follow that same pattern here, do not add a new `Action` to `permissions/model.ts`). `createMemoryFact` returning `{ fact, created }` lets the route return `201` for a genuinely new fact and `200` for one that deduped into an existing fact — same resource, correct REST status either way.

**Interfaces:**
- Consumes: `getAgent` from `../agents/repository.js`; `createMemoryFact`, `deleteMemoryFact`, `getMemoryFact`, `listMemoryFactsForAgent`, `updateMemoryFact` from `./repository.js`; `requireAuth` from `../auth/middleware.js`; `type Role` from `../permissions/model.js`.
- Produces: `registerMemoryFactRoutes(app: FastifyInstance): void`, registering:
  - `POST /api/agents/:agentId/memory-facts` — body `{ content: string; source?: 'conversation' | 'manual' | 'summary'; tags?: string[] }` (source defaults to `'manual'`), 201 on create / 200 on dedup-hit, 404 if agent doesn't exist, 403 if caller isn't the agent's owner or an admin/owner.
  - `GET /api/agents/:agentId/memory-facts` — 200 with the array, same 404/403 rules.
  - `PATCH /api/agents/:agentId/memory-facts/:factId` — body `{ content?: string; tags?: string[] }`, 200 with the updated (or merged-on-collision) fact, 404 if agent or fact doesn't exist (or the fact belongs to a different agent), 403 as above.
  - `DELETE /api/agents/:agentId/memory-facts/:factId` — 204, same 404/403 rules.

- [ ] **Step 1: Write the failing test**

Create `src/memory/routes.test.ts`:

```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { createSession } from '../auth/session.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';

describe('memory fact routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupOwnerWithAgent(app: Awaited<ReturnType<typeof buildApp>>) {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const createAgent = await app.inject({
      method: 'POST',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Assistant', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' } },
    });
    return { token, agentId: createAgent.json().id as string };
  }

  it('creates a memory fact for the owning user and returns 201', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerWithAgent(app);

    const create = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Prefers concise answers.' },
    });
    expect(create.statusCode).toBe(201);
    expect(create.json().content).toBe('Prefers concise answers.');
    expect(create.json().source).toBe('manual');

    await app.close();
  });

  it('returns 200 (not 201) when the content deduplicates into an existing fact', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerWithAgent(app);

    const first = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Likes dark mode.' },
    });
    const second = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: '  Likes DARK mode.  ' },
    });
    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(200);
    expect(second.json().id).toBe(first.json().id);

    await app.close();
  });

  it('lists memory facts for the agent', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerWithAgent(app);
    await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'One.' },
    });

    const list = await app.inject({
      method: 'GET',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toHaveLength(1);

    await app.close();
  });

  it('updates a memory fact', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerWithAgent(app);
    const create = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Original.' },
    });
    const factId = create.json().id as string;

    const update = await app.inject({
      method: 'PATCH',
      url: `/api/agents/${agentId}/memory-facts/${factId}`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Revised.' },
    });
    expect(update.statusCode).toBe(200);
    expect(update.json().content).toBe('Revised.');

    await app.close();
  });

  it('deletes a memory fact', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerWithAgent(app);
    const create = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Temporary.' },
    });
    const factId = create.json().id as string;

    const del = await app.inject({
      method: 'DELETE',
      url: `/api/agents/${agentId}/memory-facts/${factId}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(del.statusCode).toBe(204);

    const list = await app.inject({
      method: 'GET',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.json()).toHaveLength(0);

    await app.close();
  });

  it('rejects a member who neither owns the agent nor holds an admin/owner role', async () => {
    const app = await buildApp({ db });
    const { agentId } = await setupOwnerWithAgent(app);
    const member = createUser(db, { email: 'member@example.com', displayName: 'Member', passwordHash: 'x', role: 'member' });
    const memberToken = createSession(db, member.id);

    const create = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${memberToken}` },
      payload: { content: 'Should not be allowed.' },
    });
    expect(create.statusCode).toBe(403);

    await app.close();
  });

  it('returns 404 for a nonexistent agent', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwnerWithAgent(app);

    const create = await app.inject({
      method: 'POST',
      url: '/api/agents/does-not-exist/memory-facts',
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'Anything.' },
    });
    expect(create.statusCode).toBe(404);

    await app.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/memory/routes.test.ts`
Expected: FAIL — `src/memory/routes.ts` doesn't exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `src/memory/routes.ts`:

```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { getAgent } from '../agents/repository.js';
import { requireAuth } from '../auth/middleware.js';
import type { Role } from '../permissions/model.js';
import { createMemoryFact, deleteMemoryFact, getMemoryFact, listMemoryFactsForAgent, updateMemoryFact } from './repository.js';

const CreateMemoryFactBodySchema = z.object({
  content: z.string().min(1),
  source: z.enum(['conversation', 'manual', 'summary']).default('manual'),
  tags: z.array(z.string()).default([]),
});

const UpdateMemoryFactBodySchema = z.object({
  content: z.string().min(1).optional(),
  tags: z.array(z.string()).optional(),
});

function canManageAgentMemory(role: Role, requesterId: string, agentOwnerId: string): boolean {
  // Intentional: admin/owner is a site-wide trusted role in this self-host model,
  // same convention as group membership management in conversations/routes.ts.
  return requesterId === agentOwnerId || role === 'admin' || role === 'owner';
}

export function registerMemoryFactRoutes(app: FastifyInstance): void {
  app.post('/api/agents/:agentId/memory-facts', { preHandler: requireAuth }, async (request, reply) => {
    const { agentId } = request.params as { agentId: string };
    const agent = getAgent(app.db, agentId);
    if (!agent) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    if (!canManageAgentMemory(request.user!.role as Role, request.user!.id, agent.ownerUserId)) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const body = CreateMemoryFactBodySchema.parse(request.body);
    const { fact, created } = createMemoryFact(app.db, { agentId, content: body.content, source: body.source, tags: body.tags });
    reply.code(created ? 201 : 200).send(fact);
  });

  app.get('/api/agents/:agentId/memory-facts', { preHandler: requireAuth }, async (request, reply) => {
    const { agentId } = request.params as { agentId: string };
    const agent = getAgent(app.db, agentId);
    if (!agent) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    if (!canManageAgentMemory(request.user!.role as Role, request.user!.id, agent.ownerUserId)) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    reply.send(listMemoryFactsForAgent(app.db, agentId));
  });

  app.patch('/api/agents/:agentId/memory-facts/:factId', { preHandler: requireAuth }, async (request, reply) => {
    const { agentId, factId } = request.params as { agentId: string; factId: string };
    const agent = getAgent(app.db, agentId);
    if (!agent) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    if (!canManageAgentMemory(request.user!.role as Role, request.user!.id, agent.ownerUserId)) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const existing = getMemoryFact(app.db, factId);
    if (!existing || existing.agentId !== agentId) {
      reply.code(404).send({ error: 'memory_fact_not_found' });
      return;
    }
    const body = UpdateMemoryFactBodySchema.parse(request.body);
    reply.send(updateMemoryFact(app.db, factId, body));
  });

  app.delete('/api/agents/:agentId/memory-facts/:factId', { preHandler: requireAuth }, async (request, reply) => {
    const { agentId, factId } = request.params as { agentId: string; factId: string };
    const agent = getAgent(app.db, agentId);
    if (!agent) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    if (!canManageAgentMemory(request.user!.role as Role, request.user!.id, agent.ownerUserId)) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const existing = getMemoryFact(app.db, factId);
    if (!existing || existing.agentId !== agentId) {
      reply.code(404).send({ error: 'memory_fact_not_found' });
      return;
    }
    deleteMemoryFact(app.db, factId);
    reply.code(204).send();
  });
}
```

- [ ] **Step 4: Wire the routes into the app**

In `src/app.ts`, add the import alongside the other route imports (after the `registerMessageRoutes` import):

```ts
import { registerMemoryFactRoutes } from './memory/routes.js';
```

And register it alongside the other routes (after `registerMessageRoutes(app, hub);`):

```ts
  registerMemoryFactRoutes(app);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/memory/routes.test.ts`
Expected: PASS (all 7 tests).

- [ ] **Step 6: Run the full suite and typecheck**

Run: `npm test && npx tsc -p tsconfig.json --noEmit`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add src/memory/routes.ts src/memory/routes.test.ts src/app.ts
git commit -m "feat: expose MemoryFact CRUD over REST, scoped to the agent's owner"
```

---

### Task 5: Rolling conversation summaries

**Files:**
- Create: `src/db/migrations/0014_conversation_summaries.sql`
- Create: `src/memory/summary-repository.ts`
- Create: `src/memory/summary.ts`
- Test: `src/memory/summary-repository.test.ts`
- Test: `src/memory/summary.test.ts`

**Context:** Uses the `ConversationSummary` schema already defined in `@opencrew/protocol`. `SummarizeFn` is a seam that mirrors `RespondFn`'s pattern in `src/runtime/engine.ts`: a deterministic default (`defaultSummarize`) is the production default until a real LLM-backed summarizer is wired in a later plan (the same evolutionary path `defaultRespond` took before `server-providers` wired `createProviderRespond`). `defaultSummarize` must stay pure and deterministic — no provider/network calls — per this plan's Global Constraints. `updateConversationSummary` is the orchestration function: it reads the most recent messages (via `listRecentMessagesForConversation` from Task 1 — this is exactly the function that task fixed), reads any prior stored summary, calls the injected `summarize`, and persists the result keyed by the last message it incorporated.

**Interfaces:**
- Consumes: `ConversationSummarySchema`, `type ConversationSummary` from `@opencrew/protocol`; `listRecentMessagesForConversation` from `../messages/repository.js` (Task 1).
- Produces (`summary-repository.ts`): `getConversationSummary(db, conversationId: string): ConversationSummary | undefined`; `upsertConversationSummary(db, input: { conversationId: string; summary: string; upToMessageId: string }): ConversationSummary`.
- Produces (`summary.ts`): `type SummarizeFn = (input: { conversationId: string; priorSummary: string | null; messages: Message[] }) => Promise<string>`; `defaultSummarize: SummarizeFn`; `updateConversationSummary(db, conversationId: string, summarize?: SummarizeFn): Promise<ConversationSummary | undefined>` (returns `undefined` only when the conversation has no messages yet); `SUMMARIZE_CONVERSATION_JOB_TYPE: string` (the job-type constant, `'summarize-conversation'`, so Task 6 doesn't hardcode the string in two places).
- Consumes (Task 6, 7): everything `summary.ts` produces, plus `getConversationSummary` from `summary-repository.ts`.

- [ ] **Step 1: Write the migration**

Create `src/db/migrations/0014_conversation_summaries.sql`:

```sql
CREATE TABLE conversation_summaries (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
  summary TEXT NOT NULL,
  up_to_message_id TEXT NOT NULL REFERENCES messages(id),
  updated_at TEXT NOT NULL
);
```

- [ ] **Step 2: Write the failing summary-repository test**

Create `src/memory/summary-repository.test.ts`:

```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createMessage } from '../messages/repository.js';
import { getConversationSummary, upsertConversationSummary } from './summary-repository.js';

describe('conversation summary repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithMessage() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-summary-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const alice = createUser(db, { email: 'alice@example.com', displayName: 'Alice', passwordHash: 'x', role: 'owner' });
    const conversation = createConversation(db, { kind: 'dm', name: null, participants: [{ participantId: alice.id, participantType: 'user' }] });
    const message = createMessage(db, {
      conversationId: conversation.id,
      authorId: alice.id,
      authorType: 'user',
      body: 'hello',
      mentions: [],
      replyToMessageId: null,
    });
    return { db, conversation, message };
  }

  it('returns undefined when no summary exists yet', () => {
    const { db, conversation } = freshDbWithMessage();
    expect(getConversationSummary(db, conversation.id)).toBeUndefined();
    db.close();
  });

  it('creates then updates a summary for the same conversation', () => {
    const { db, conversation, message } = freshDbWithMessage();
    const created = upsertConversationSummary(db, { conversationId: conversation.id, summary: 'first pass', upToMessageId: message.id });
    expect(created.summary).toBe('first pass');

    const updated = upsertConversationSummary(db, { conversationId: conversation.id, summary: 'second pass', upToMessageId: message.id });
    expect(updated.summary).toBe('second pass');
    expect(getConversationSummary(db, conversation.id)?.summary).toBe('second pass');
    db.close();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run src/memory/summary-repository.test.ts`
Expected: FAIL — `src/memory/summary-repository.ts` doesn't exist yet.

- [ ] **Step 4: Write the minimal implementation**

Create `src/memory/summary-repository.ts`:

```ts
import { ConversationSummarySchema, type ConversationSummary } from '@opencrew/protocol';
import type Database from 'better-sqlite3';

interface ConversationSummaryRow {
  conversation_id: string;
  summary: string;
  up_to_message_id: string;
  updated_at: string;
}

function rowToSummary(row: ConversationSummaryRow): ConversationSummary {
  return ConversationSummarySchema.parse({
    conversationId: row.conversation_id,
    summary: row.summary,
    upToMessageId: row.up_to_message_id,
    updatedAt: row.updated_at,
  });
}

export function getConversationSummary(db: Database.Database, conversationId: string): ConversationSummary | undefined {
  const row = db.prepare('SELECT * FROM conversation_summaries WHERE conversation_id = ?').get(conversationId) as
    | ConversationSummaryRow
    | undefined;
  return row ? rowToSummary(row) : undefined;
}

export function upsertConversationSummary(
  db: Database.Database,
  input: { conversationId: string; summary: string; upToMessageId: string }
): ConversationSummary {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO conversation_summaries (conversation_id, summary, up_to_message_id, updated_at)
     VALUES (@conversation_id, @summary, @up_to_message_id, @updated_at)
     ON CONFLICT(conversation_id) DO UPDATE SET
       summary = excluded.summary,
       up_to_message_id = excluded.up_to_message_id,
       updated_at = excluded.updated_at`
  ).run({ conversation_id: input.conversationId, summary: input.summary, up_to_message_id: input.upToMessageId, updated_at: now });
  return getConversationSummary(db, input.conversationId)!;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/memory/summary-repository.test.ts`
Expected: PASS.

- [ ] **Step 6: Write the failing summary orchestration test**

Create `src/memory/summary.test.ts`:

```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createMessage } from '../messages/repository.js';
import { getConversationSummary } from './summary-repository.js';
import { defaultSummarize, updateConversationSummary, type SummarizeFn } from './summary.js';

describe('conversation summary orchestration', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithConversation() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-summary-orch-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const alice = createUser(db, { email: 'alice@example.com', displayName: 'Alice', passwordHash: 'x', role: 'owner' });
    const conversation = createConversation(db, { kind: 'dm', name: null, participants: [{ participantId: alice.id, participantType: 'user' }] });
    return { db, alice, conversation };
  }

  it('returns undefined when the conversation has no messages yet', async () => {
    const { db, conversation } = freshDbWithConversation();
    const result = await updateConversationSummary(db, conversation.id);
    expect(result).toBeUndefined();
    db.close();
  });

  it('persists a summary built from the conversation messages using the default summarizer', async () => {
    const { db, alice, conversation } = freshDbWithConversation();
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'first message', mentions: [], replyToMessageId: null });

    const result = await updateConversationSummary(db, conversation.id);

    expect(result?.summary).toContain('first message');
    expect(getConversationSummary(db, conversation.id)?.summary).toBe(result?.summary);
    db.close();
  });

  it('passes the prior summary text into the summarizer on a second call', async () => {
    const { db, alice, conversation } = freshDbWithConversation();
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'first', mentions: [], replyToMessageId: null });
    await updateConversationSummary(db, conversation.id);

    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'second', mentions: [], replyToMessageId: null });
    const seenPriorSummaries: (string | null)[] = [];
    const spy: SummarizeFn = async (input) => {
      seenPriorSummaries.push(input.priorSummary);
      return 'stub summary';
    };
    await updateConversationSummary(db, conversation.id, spy);

    expect(seenPriorSummaries).toHaveLength(1);
    expect(seenPriorSummaries[0]).toContain('first');
    db.close();
  });

  it('uses an injected custom summarize function instead of the default', async () => {
    const { db, alice, conversation } = freshDbWithConversation();
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'hello', mentions: [], replyToMessageId: null });
    const custom: SummarizeFn = async () => 'custom summary text';

    const result = await updateConversationSummary(db, conversation.id, custom);

    expect(result?.summary).toBe('custom summary text');
    db.close();
  });

  it('defaultSummarize is pure: same input always produces the same output', async () => {
    const messages = [
      { id: 'm1', conversationId: 'c1', authorId: 'u1', authorType: 'user' as const, body: 'hi', mentions: [], replyToMessageId: null, createdAt: new Date().toISOString() },
    ];
    const first = await defaultSummarize({ conversationId: 'c1', priorSummary: null, messages });
    const second = await defaultSummarize({ conversationId: 'c1', priorSummary: null, messages });
    expect(first).toBe(second);
  });
});
```

- [ ] **Step 7: Run test to verify it fails**

Run: `npx vitest run src/memory/summary.test.ts`
Expected: FAIL — `src/memory/summary.ts` doesn't exist yet.

- [ ] **Step 8: Write the minimal implementation**

Create `src/memory/summary.ts`:

```ts
import type { ConversationSummary, Message } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { listRecentMessagesForConversation } from '../messages/repository.js';
import { getConversationSummary, upsertConversationSummary } from './summary-repository.js';

export const SUMMARIZE_CONVERSATION_JOB_TYPE = 'summarize-conversation';

export type SummarizeFn = (input: {
  conversationId: string;
  priorSummary: string | null;
  messages: Message[];
}) => Promise<string>;

const MAX_SUMMARY_MESSAGES = 20;
const MAX_SUMMARY_LENGTH = 2000;

export const defaultSummarize: SummarizeFn = async ({ priorSummary, messages }) => {
  const recap = messages.map((m) => `${m.authorType}:${m.authorId}: ${m.body}`).join('\n');
  const combined = priorSummary ? `${priorSummary}\n${recap}` : recap;
  return combined.length > MAX_SUMMARY_LENGTH ? combined.slice(combined.length - MAX_SUMMARY_LENGTH) : combined;
};

export async function updateConversationSummary(
  db: Database.Database,
  conversationId: string,
  summarize: SummarizeFn = defaultSummarize
): Promise<ConversationSummary | undefined> {
  const messages = listRecentMessagesForConversation(db, conversationId, MAX_SUMMARY_MESSAGES);
  if (messages.length === 0) return undefined;

  const prior = getConversationSummary(db, conversationId);
  const summaryText = await summarize({
    conversationId,
    priorSummary: prior?.summary ?? null,
    messages,
  });

  return upsertConversationSummary(db, {
    conversationId,
    summary: summaryText,
    upToMessageId: messages[messages.length - 1].id,
  });
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `npx vitest run src/memory/summary.test.ts`
Expected: PASS (all 5 tests).

- [ ] **Step 10: Run the full suite and typecheck**

Run: `npm test && npx tsc -p tsconfig.json --noEmit`
Expected: both clean.

- [ ] **Step 11: Commit**

```bash
git add src/db/migrations/0014_conversation_summaries.sql src/memory/summary-repository.ts src/memory/summary.ts src/memory/summary-repository.test.ts src/memory/summary.test.ts
git commit -m "feat: add rolling conversation summary regeneration behind a SummarizeFn seam"
```

---

### Task 6: Trigger summary regeneration as a background job, expose it over REST, wire the job runner into production

**Files:**
- Modify: `src/messages/routes.ts` (enqueue a summary job after a user posts a message)
- Modify: `src/runtime/engine.ts` (enqueue a summary job after an agent's message is persisted — this is the one place in this plan that touches `engine.ts` again after Task 1; it is in-scope here because this plan owns wiring the memory layer into the runtime, unlike `server-providers`, which was explicitly told not to touch this file)
- Modify: `src/memory/routes.ts` (add `registerConversationSummaryRoutes`, the `GET` endpoint)
- Modify: `src/app.ts` (register the new route function, wire `JobRunner` is NOT done here — that's production-only, done in `index.ts` in this same task)
- Modify: `src/index.ts` (construct the `JobRunner` with the real handler and start it)
- Test: `src/messages/routes.test.ts` (add a test)
- Test: `src/runtime/engine.test.ts` (add a test)
- Test: `src/memory/routes.test.ts` (add tests for the new summary route)

**Context:** Every place a message gets persisted (`src/messages/routes.ts`'s `POST /api/conversations/:id/messages` for user messages, `src/runtime/engine.ts`'s `runAgentTurn` for agent messages) should enqueue a `SUMMARIZE_CONVERSATION_JOB_TYPE` job with `dedupeKey: `${SUMMARIZE_CONVERSATION_JOB_TYPE}:${conversationId}``, so a burst of messages collapses into one pending regeneration (Task 2's dedup mechanism exists exactly for this). The `JobRunner` itself is only ever started in `index.ts`'s production `main()` — never inside `buildApp` — following the same "production-only wiring, deterministic default/no wiring in tests" pattern `server-providers` established for `createProviderRespond` (`buildApp`'s own defaults are untouched by this plan; nothing in `app.ts` starts a timer).

**Interfaces:**
- Consumes: `enqueueJob` from `../jobs/repository.js` (Task 2); `SUMMARIZE_CONVERSATION_JOB_TYPE`, `updateConversationSummary` from `../memory/summary.js` (Task 5); `getConversationSummary` from `../memory/summary-repository.js` (Task 5); `JobRunner` from `../jobs/runner.js` (Task 2).
- Produces: `registerConversationSummaryRoutes(app: FastifyInstance): void`, registering `GET /api/conversations/:id/summary` (participant-gated like `src/messages/routes.ts`'s existing routes — reuses `isParticipant`; 404 if no conversation, 403 if not a participant, 404 if no summary has been generated yet, 200 with the `ConversationSummary` otherwise).

- [ ] **Step 1: Write the failing test for message-triggered enqueue**

Add to `src/messages/routes.test.ts` (find the existing `describe` block for message routes and add this test; check the file's existing imports first — it likely already imports `runMigrations`, `buildApp`, etc. in the same style as `src/providers/routes.test.ts`):

```ts
  it('enqueues a summarize-conversation job after a message is posted', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const createAgent = await app.inject({
      method: 'POST',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Assistant', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' } },
    });
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: createAgent.json().id, participantType: 'agent' },
    });
    const conversationId = dm.json().id as string;

    await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
      payload: { body: 'hello' },
    });

    const row = db.prepare("SELECT type, status FROM jobs WHERE type = 'summarize-conversation'").get() as
      | { type: string; status: string }
      | undefined;
    expect(row?.status).toBe('pending');

    await app.close();
  });
```

Adjust this test to whatever `describe`/setup structure `src/messages/routes.test.ts` already uses (read the file first — reuse its existing `db`/`beforeEach` pattern rather than redeclaring one).

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/messages/routes.test.ts`
Expected: FAIL — no row found (`row` is `undefined`), since nothing enqueues a job yet.

- [ ] **Step 3: Wire the enqueue call into the message POST route**

In `src/messages/routes.ts`, add to the imports:

```ts
import { enqueueJob } from '../jobs/repository.js';
import { SUMMARIZE_CONVERSATION_JOB_TYPE } from '../memory/summary.js';
```

Then, in the `POST /api/conversations/:id/messages` handler, right after `hub.publish(`conversation:${id}`, 'message.created', { ...message });` and before `reply.code(201).send(message);`, add:

```ts
    enqueueJob(app.db, {
      type: SUMMARIZE_CONVERSATION_JOB_TYPE,
      payload: { conversationId: id },
      dedupeKey: `${SUMMARIZE_CONVERSATION_JOB_TYPE}:${id}`,
    });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/messages/routes.test.ts`
Expected: PASS.

- [ ] **Step 5: Write the failing test for agent-turn-triggered enqueue**

`src/runtime/engine.test.ts` already has a `freshSetup()` helper (inside its `describe('runAgentTurn (single turn, no handoff)', ...)` block) that returns `{ db, agent, conversation, hub }`, with one message already posted to the conversation. Add this test into that same `describe` block, alongside the other tests that call `runAgentTurn({ db, hub, respond }, { agentId: agent.id, conversationId: conversation.id })`:

```ts
  it('enqueues a summarize-conversation job after persisting the agent message', async () => {
    const { db, agent, conversation, hub } = freshSetup();
    const respond = vi.fn(async (): Promise<AgentTurnResult> => ({ body: 'hello human' }));

    await runAgentTurn({ db, hub, respond }, { agentId: agent.id, conversationId: conversation.id });

    const row = db.prepare("SELECT status FROM jobs WHERE type = 'summarize-conversation'").get() as
      | { status: string }
      | undefined;
    expect(row?.status).toBe('pending');
    db.close();
  });
```

- [ ] **Step 6: Run test to verify it fails**

Run: `npx vitest run src/runtime/engine.test.ts`
Expected: FAIL — no job row found.

- [ ] **Step 7: Wire the enqueue call into runAgentTurn**

In `src/runtime/engine.ts`, add to the imports:

```ts
import { enqueueJob } from '../jobs/repository.js';
import { SUMMARIZE_CONVERSATION_JOB_TYPE } from '../memory/summary.js';
```

Then, right after the existing line `deps.hub.publish(\`conversation:${input.conversationId}\`, 'message.created', { ...message });` (around line 81), add:

```ts
  enqueueJob(deps.db, {
    type: SUMMARIZE_CONVERSATION_JOB_TYPE,
    payload: { conversationId: input.conversationId },
    dedupeKey: `${SUMMARIZE_CONVERSATION_JOB_TYPE}:${input.conversationId}`,
  });
```

- [ ] **Step 8: Run test to verify it passes**

Run: `npx vitest run src/runtime/engine.test.ts`
Expected: PASS.

- [ ] **Step 9: Write the failing test for the GET summary route**

Add to `src/memory/routes.test.ts` (in the same `describe` block, reusing its existing `setupOwnerWithAgent`-style helpers, or writing an equivalent one for conversations — read the file's current content first since Task 4 already wrote it):

```ts
  it('returns 404 for a conversation with no summary yet', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const other = createUser(db, { email: 'other@example.com', displayName: 'Other', passwordHash: 'x', role: 'member' });
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: other.id, participantType: 'user' },
    });
    const conversationId = dm.json().id as string;

    const get = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/summary`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(404);

    await app.close();
  });

  it('returns a generated summary once one exists', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const other = createUser(db, { email: 'other2@example.com', displayName: 'Other2', passwordHash: 'x', role: 'member' });
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: other.id, participantType: 'user' },
    });
    const conversationId = dm.json().id as string;
    await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
      payload: { body: 'summarize me' },
    });
    await updateConversationSummary(db, conversationId);

    const get = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/summary`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(get.json().summary).toContain('summarize me');

    await app.close();
  });
```

Add the needed imports at the top of `src/memory/routes.test.ts`: `updateConversationSummary` from `./summary.js`, and `createUser` from `../users/repository.js` (it may already be imported for another test in this file — check before duplicating the import).

- [ ] **Step 10: Run test to verify it fails**

Run: `npx vitest run src/memory/routes.test.ts`
Expected: FAIL — route doesn't exist (404 for a nonexistent route on the first test may accidentally pass by coincidence; the second test fails clearly since the route returns 404 "not found" for the route itself rather than a real summary).

- [ ] **Step 11: Add the GET summary route**

In `src/memory/routes.ts`, add to the imports:

```ts
import { getConversation, isParticipant } from '../conversations/repository.js';
import { getConversationSummary } from './summary-repository.js';
```

Then add this new exported function at the end of the file, after `registerMemoryFactRoutes`:

```ts
export function registerConversationSummaryRoutes(app: FastifyInstance): void {
  app.get('/api/conversations/:id/summary', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const conversation = getConversation(app.db, id);
    if (!conversation) {
      reply.code(404).send({ error: 'conversation_not_found' });
      return;
    }
    if (!isParticipant(app.db, id, request.user!.id, 'user')) {
      reply.code(403).send({ error: 'not_a_participant' });
      return;
    }
    const summary = getConversationSummary(app.db, id);
    if (!summary) {
      reply.code(404).send({ error: 'summary_not_found' });
      return;
    }
    reply.send(summary);
  });
}
```

- [ ] **Step 12: Wire the new route registration into the app**

In `src/app.ts`, change the memory import (added in Task 4) to also pull in the new function:

```ts
import { registerConversationSummaryRoutes, registerMemoryFactRoutes } from './memory/routes.js';
```

And register it alongside `registerMemoryFactRoutes(app);`:

```ts
  registerMemoryFactRoutes(app);
  registerConversationSummaryRoutes(app);
```

- [ ] **Step 13: Run test to verify it passes**

Run: `npx vitest run src/memory/routes.test.ts`
Expected: PASS (all tests in the file, original 7 plus the 2 new ones).

- [ ] **Step 14: Wire the JobRunner into production**

In `src/index.ts`, add to the imports:

```ts
import { JobRunner } from './jobs/runner.js';
import { SUMMARIZE_CONVERSATION_JOB_TYPE, updateConversationSummary } from './memory/summary.js';
```

Then, inside `main()`, after `const app = await buildApp({ db, respond: createProviderRespond(db) });` and before `await app.listen(...)`, add:

```ts
  const jobRunner = new JobRunner(db, {
    [SUMMARIZE_CONVERSATION_JOB_TYPE]: async (jobDb, payload) => {
      const { conversationId } = payload as { conversationId: string };
      await updateConversationSummary(jobDb, conversationId);
    },
  });
  jobRunner.start();
```

- [ ] **Step 15: Run the full suite and typecheck**

Run: `npm test && npx tsc -p tsconfig.json --noEmit`
Expected: both clean.

- [ ] **Step 16: Commit**

```bash
git add src/messages/routes.ts src/messages/routes.test.ts src/runtime/engine.ts src/runtime/engine.test.ts src/memory/routes.ts src/memory/routes.test.ts src/app.ts src/index.ts
git commit -m "feat: trigger conversation summary regeneration on message activity and expose it over REST"
```

---

### Task 7: End-to-end proof — memory persistence, dedup, and summary regeneration through the real stack

**Files:**
- Create: `test/memory-e2e.test.ts`

**Context:** This is the plan's capstone test for the charter's "memory persistence" testing minimum — it must prove the whole chain works through the real HTTP surface and a real (not directly-called) job execution, not just that each unit works in isolation. Follow the same shape as `test/provider-e2e.test.ts` and `test/runtime-e2e.test.ts`: a real `buildApp`, real REST calls, and — since the `JobRunner`'s timer is never started inside `buildApp` (Task 6 wires it only in `index.ts`'s production `main()`) — a manually constructed `JobRunner` calling `runOnce()` directly against the same `db`, which is exactly the deterministic seam Task 2 built it for.

**Interfaces:**
- Consumes: `buildApp` from `../src/app.js`; `runMigrations` from `../src/db/migrate.js`; `JobRunner` from `../src/jobs/runner.js`; `SUMMARIZE_CONVERSATION_JOB_TYPE`, `updateConversationSummary` from `../src/memory/summary.js`.

- [ ] **Step 1: Write the test**

Create `test/memory-e2e.test.ts`:

```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { runMigrations } from '../src/db/migrate.js';
import { JobRunner } from '../src/jobs/runner.js';
import { SUMMARIZE_CONVERSATION_JOB_TYPE, updateConversationSummary } from '../src/memory/summary.js';

describe('memory end-to-end: MemoryFact dedup and conversation summary regeneration', () => {
  let db: Database.Database;
  let app: Awaited<ReturnType<typeof buildApp>>;

  beforeEach(async () => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
    app = await buildApp({ db });
  });

  afterEach(async () => {
    await app.close();
    db.close();
  });

  it('deduplicates a memory fact created twice through the real REST surface', async () => {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const createAgent = await app.inject({
      method: 'POST',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Assistant', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' } },
    });
    const agentId = createAgent.json().id as string;

    const first = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: 'User prefers terse replies.' },
    });
    const second = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
      payload: { content: '  User PREFERS terse replies.  ' },
    });

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(200);
    expect(second.json().id).toBe(first.json().id);

    const list = await app.inject({
      method: 'GET',
      url: `/api/agents/${agentId}/memory-facts`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.json()).toHaveLength(1);
  });

  it('collapses a burst of messages into one pending job, and running it produces a fetchable summary', async () => {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const other = await app.inject({
      method: 'POST',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Assistant', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' } },
    });
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: other.json().id, participantType: 'agent' },
    });
    const conversationId = dm.json().id as string;

    for (const body of ['first', 'second', 'third']) {
      await app.inject({
        method: 'POST',
        url: `/api/conversations/${conversationId}/messages`,
        headers: { authorization: `Bearer ${token}` },
        payload: { body },
      });
    }

    const pendingCount = db.prepare("SELECT COUNT(*) as n FROM jobs WHERE type = ? AND status = 'pending'").get(
      SUMMARIZE_CONVERSATION_JOB_TYPE
    ) as { n: number };
    expect(pendingCount.n).toBe(1);

    const runner = new JobRunner(db, {
      [SUMMARIZE_CONVERSATION_JOB_TYPE]: async (jobDb, payload) => {
        const { conversationId: cid } = payload as { conversationId: string };
        await updateConversationSummary(jobDb, cid);
      },
    });
    const ran = await runner.runOnce();
    expect(ran).toBe(true);

    const summary = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/summary`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(summary.statusCode).toBe(200);
    expect(summary.json().summary).toContain('first');
    expect(summary.json().summary).toContain('third');
  });
});
```

- [ ] **Step 2: Run test to verify it passes**

Run: `npx vitest run test/memory-e2e.test.ts`
Expected: PASS (both tests).

- [ ] **Step 3: Run the full suite, typecheck, and build**

Run: `npm test`
Expected: PASS, full suite (prior 125 tests plus this plan's new ones).

Run: `npx tsc -p tsconfig.json --noEmit`
Expected: clean.

Run: `npm run build`
Expected: clean. Then verify the build output has no stray test files and all migrations are present:

```bash
find dist -name "*.test.*"
ls dist/db/migrations
```

Expected: the `find` command prints nothing; `ls` lists all 14 migration files including `0012_jobs.sql`, `0013_memory_facts.sql`, `0014_conversation_summaries.sql`.

- [ ] **Step 4: Commit**

```bash
git add test/memory-e2e.test.ts
git commit -m "test: prove MemoryFact dedup and job-driven summary regeneration end-to-end"
```
