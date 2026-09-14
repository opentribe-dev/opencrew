# Server Runtime and Agent-to-Agent Messaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add RuntimeBinding/RuntimeSession persistence, a Native Agent runtime
loop (in-process, no agentd dependency), agent-to-agent handoff with
`rootRunId`/`causationId`/`hopCount` enforcement, and approvals to
`@opencrew/server`.

**Architecture:** Two new modules, `runtime/` and `approvals/`, follow the
established repository+routes pattern (`AgentSchema.parse`-validated rows
over raw SQL, thin Fastify routes behind `requireAuth`). The runtime's
"thinking" step is an injected `RespondFn` — a swappable `(input) =>
Promise<AgentTurnResult>` function, defaulting to a deterministic stub in
production and replaceable per-test — so the not-yet-written
`server-providers` plan can slot a real LLM call in later without touching
this plan's persistence or orchestration code. Agent-to-agent handoff is a
same-process recursive call (`runAgentTurn` calling itself), not a queue: an
agent's response can optionally name another agent to hand off to, and the
engine dispatches a follow-up run with `hopCount + 1`, refusing once
`hopCount` would exceed `@opencrew/protocol`'s `DEFAULT_MAX_HOP_COUNT` (4).

**Tech Stack:** Same as `@opencrew/server` — Fastify 5, better-sqlite3,
`@opencrew/protocol`, Zod, Vitest 2. No new dependencies, no message queue,
no agentd dependency (agentd doesn't exist in this workspace yet — see "What
this plan deliberately leaves out").

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- One server process, SQLite+WAL, no external services — no message queue
  for agent-to-agent dispatch, it's an in-process recursive call.
- Agent != Runtime != Runtime Session. `RuntimeSession = Agent + Conversation
  + Runtime + Workspace` — a join of existing `agents`/`conversations` rows
  plus a new `runtime_bindings`/`runtime_sessions` pair, never merged into
  one table.
- Vendor-specific session IDs live on `RuntimeBinding.vendorState`
  (`@opencrew/protocol`'s `AgentSchema` is already `.strict()` and rejects
  them on the core Agent row — this plan must not add a backdoor around that).
- Agent-to-agent runs carry `rootRunId`, `causationId`, `hopCount`; hard max
  is `DEFAULT_MAX_HOP_COUNT` (4), enforced both at the DB layer (a `CHECK`
  constraint) and at the engine layer (a graceful stop, not a crash, when a
  handoff chain would exceed it).
- agentd is NOT a remote shell. The only operations this codebase may ever
  construct as requests to agentd are the six named ones (`runtime.run`,
  `runtime.resume`, `provider.chat`, `provider.models`, `workspace.list`,
  `approval.respond`) — this plan doesn't call agentd at all (it doesn't
  exist in this workspace yet), but no task here should invent anything
  resembling an arbitrary command.
- Untested work must not be reported as completed.

## Prerequisite

`repos/server` is on `main` (protocol-foundations, server-foundations, and
server-messaging-core plans all merged) and `repos/protocol` is on `main`
with the `runtime.ts`/`agentd.ts`/`approval.ts` schemas already published.
This plan works on `repos/server`'s `main` via a new feature branch. Next
migration number is `0007` (`0001`-`0006` already exist).

---

## File Structure

```
repos/server/
  src/
    app.ts                                  # modified: wire runtime + approval routes, respond seam
    runtime/
      bindings.ts
      bindings.test.ts
      sessions.ts
      sessions.test.ts
      runs.ts
      runs.test.ts
      engine.ts
      engine.test.ts
      routes.ts
      routes.test.ts
    approvals/
      repository.ts
      repository.test.ts
      routes.ts
      routes.test.ts
    db/
      migrations/
        0007_runtime_bindings.sql
        0008_runtime_sessions.sql
        0009_agent_runs.sql
        0010_approvals.sql
  test/
    runtime-e2e.test.ts
```

---

### Task 1: Runtime binding and session persistence

**Files:**
- Create: `repos/server/src/db/migrations/0007_runtime_bindings.sql`
- Create: `repos/server/src/db/migrations/0008_runtime_sessions.sql`
- Create: `repos/server/src/runtime/bindings.ts`
- Test: `repos/server/src/runtime/bindings.test.ts`
- Create: `repos/server/src/runtime/sessions.ts`
- Test: `repos/server/src/runtime/sessions.test.ts`

**Interfaces:**
- Consumes: `RuntimeBindingSchema`, `RuntimeBinding`, `RuntimeKind`,
  `RuntimeSessionSchema`, `RuntimeSession`, `RuntimeSessionStatus` from
  `@opencrew/protocol` (already published). `createUser` from
  `../users/repository.js`, `createAgent` from `../agents/repository.js`,
  `createConversation` from `../conversations/repository.js` (test fixtures).
- Produces: `createRuntimeBinding(db, { agentId, runtimeKind, workspacePath,
  vendorState? }): RuntimeBinding`, `getRuntimeBinding(db, id): RuntimeBinding
  | undefined`, `listRuntimeBindingsForAgent(db, agentId): RuntimeBinding[]`.
  `createRuntimeSession(db, { agentId, conversationId, runtimeBindingId,
  status? }): RuntimeSession`, `getRuntimeSession(db, id): RuntimeSession |
  undefined`, `updateRuntimeSessionStatus(db, id, status): RuntimeSession |
  undefined`. Every later task builds on these exact names.

This task exists to prove the "vendor session IDs live on RuntimeBinding, not
Agent" invariant and the "RuntimeSession = Agent + Conversation + Runtime +
Workspace" composition — both files are reviewed together for that reason.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/runtime/bindings.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createRuntimeBinding, getRuntimeBinding, listRuntimeBindingsForAgent } from './bindings.js';

describe('runtime bindings repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithAgent() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-bindings-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    return { db, agent };
  }

  it('creates a native runtime binding and reads it back', () => {
    const { db, agent } = freshDbWithAgent();
    const binding = createRuntimeBinding(db, {
      agentId: agent.id,
      runtimeKind: 'native',
      workspacePath: '/workspaces/assistant',
    });
    expect(binding.runtimeKind).toBe('native');
    expect(getRuntimeBinding(db, binding.id)?.id).toBe(binding.id);
    db.close();
  });

  it('round-trips vendor state without putting it on the Agent row', () => {
    const { db, agent } = freshDbWithAgent();
    const binding = createRuntimeBinding(db, {
      agentId: agent.id,
      runtimeKind: 'claude-code',
      workspacePath: '/workspaces/assistant',
      vendorState: { claudeSessionId: 'sess_abc123' },
    });
    const fetched = getRuntimeBinding(db, binding.id);
    expect(fetched?.vendorState.claudeSessionId).toBe('sess_abc123');
    db.close();
  });

  it('lists bindings for a given agent', () => {
    const { db, agent } = freshDbWithAgent();
    createRuntimeBinding(db, { agentId: agent.id, runtimeKind: 'native', workspacePath: '/a' });
    createRuntimeBinding(db, { agentId: agent.id, runtimeKind: 'native', workspacePath: '/b' });
    expect(listRuntimeBindingsForAgent(db, agent.id)).toHaveLength(2);
    db.close();
  });
});
```

`repos/server/src/runtime/sessions.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createRuntimeBinding, getRuntimeBinding } from './bindings.js';
import { createRuntimeSession, getRuntimeSession, updateRuntimeSessionStatus } from './sessions.js';

describe('runtime sessions repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithAgentAndConversation() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-sessions-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: owner.id, participantType: 'user' },
        { participantId: agent.id, participantType: 'agent' },
      ],
    });
    const binding = createRuntimeBinding(db, { agentId: agent.id, runtimeKind: 'native', workspacePath: '/ws' });
    return { db, owner, agent, conversation, binding };
  }

  it('creates a session that composes agent + conversation + runtime + workspace', () => {
    const { db, agent, conversation, binding } = freshDbWithAgentAndConversation();
    const session = createRuntimeSession(db, {
      agentId: agent.id,
      conversationId: conversation.id,
      runtimeBindingId: binding.id,
    });
    expect(session.status).toBe('idle');

    const fetched = getRuntimeSession(db, session.id);
    expect(fetched?.agentId).toBe(agent.id);
    expect(fetched?.conversationId).toBe(conversation.id);
    const fetchedBinding = getRuntimeBinding(db, fetched!.runtimeBindingId);
    expect(fetchedBinding?.workspacePath).toBe('/ws');
    db.close();
  });

  it('updates session status idle -> running -> closed', () => {
    const { db, agent, conversation, binding } = freshDbWithAgentAndConversation();
    const session = createRuntimeSession(db, {
      agentId: agent.id,
      conversationId: conversation.id,
      runtimeBindingId: binding.id,
    });
    updateRuntimeSessionStatus(db, session.id, 'running');
    expect(getRuntimeSession(db, session.id)?.status).toBe('running');
    updateRuntimeSessionStatus(db, session.id, 'closed');
    expect(getRuntimeSession(db, session.id)?.status).toBe('closed');
    db.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/runtime/bindings.test.ts src/runtime/sessions.test.ts`
Expected: FAIL — modules and tables don't exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0007_runtime_bindings.sql`:
```sql
CREATE TABLE runtime_bindings (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  runtime_kind TEXT NOT NULL CHECK (runtime_kind IN ('native', 'claude-code', 'codex', 'gemini-cli')),
  workspace_path TEXT NOT NULL,
  vendor_state TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_runtime_bindings_agent ON runtime_bindings (agent_id);
```

`repos/server/src/db/migrations/0008_runtime_sessions.sql`:
```sql
CREATE TABLE runtime_sessions (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  runtime_binding_id TEXT NOT NULL REFERENCES runtime_bindings(id),
  status TEXT NOT NULL CHECK (status IN ('idle', 'running', 'waiting_approval', 'error', 'closed')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_runtime_sessions_agent_conversation ON runtime_sessions (agent_id, conversation_id);
```

`repos/server/src/runtime/bindings.ts`:
```ts
import { RuntimeBindingSchema, type RuntimeBinding, type RuntimeKind } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface RuntimeBindingRow {
  id: string;
  agent_id: string;
  runtime_kind: RuntimeKind;
  workspace_path: string;
  vendor_state: string;
  created_at: string;
  updated_at: string;
}

function rowToRuntimeBinding(row: RuntimeBindingRow): RuntimeBinding {
  return RuntimeBindingSchema.parse({
    id: row.id,
    agentId: row.agent_id,
    runtimeKind: row.runtime_kind,
    workspacePath: row.workspace_path,
    vendorState: JSON.parse(row.vendor_state),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

export function createRuntimeBinding(
  db: Database.Database,
  input: { agentId: string; runtimeKind: RuntimeKind; workspacePath: string; vendorState?: Record<string, unknown> }
): RuntimeBinding {
  const now = new Date().toISOString();
  const row: RuntimeBindingRow = {
    id: randomUUID(),
    agent_id: input.agentId,
    runtime_kind: input.runtimeKind,
    workspace_path: input.workspacePath,
    vendor_state: JSON.stringify(input.vendorState ?? {}),
    created_at: now,
    updated_at: now,
  };
  db.prepare(
    `INSERT INTO runtime_bindings (id, agent_id, runtime_kind, workspace_path, vendor_state, created_at, updated_at)
     VALUES (@id, @agent_id, @runtime_kind, @workspace_path, @vendor_state, @created_at, @updated_at)`
  ).run(row);
  return rowToRuntimeBinding(row);
}

export function getRuntimeBinding(db: Database.Database, id: string): RuntimeBinding | undefined {
  const row = db.prepare('SELECT * FROM runtime_bindings WHERE id = ?').get(id) as RuntimeBindingRow | undefined;
  return row ? rowToRuntimeBinding(row) : undefined;
}

export function listRuntimeBindingsForAgent(db: Database.Database, agentId: string): RuntimeBinding[] {
  const rows = db.prepare('SELECT * FROM runtime_bindings WHERE agent_id = ?').all(agentId) as RuntimeBindingRow[];
  return rows.map(rowToRuntimeBinding);
}
```

`repos/server/src/runtime/sessions.ts`:
```ts
import { RuntimeSessionSchema, type RuntimeSession, type RuntimeSessionStatus } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface RuntimeSessionRow {
  id: string;
  agent_id: string;
  conversation_id: string;
  runtime_binding_id: string;
  status: RuntimeSessionStatus;
  created_at: string;
  updated_at: string;
}

function rowToRuntimeSession(row: RuntimeSessionRow): RuntimeSession {
  return RuntimeSessionSchema.parse({
    id: row.id,
    agentId: row.agent_id,
    conversationId: row.conversation_id,
    runtimeBindingId: row.runtime_binding_id,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

export function createRuntimeSession(
  db: Database.Database,
  input: { agentId: string; conversationId: string; runtimeBindingId: string; status?: RuntimeSessionStatus }
): RuntimeSession {
  const now = new Date().toISOString();
  const row: RuntimeSessionRow = {
    id: randomUUID(),
    agent_id: input.agentId,
    conversation_id: input.conversationId,
    runtime_binding_id: input.runtimeBindingId,
    status: input.status ?? 'idle',
    created_at: now,
    updated_at: now,
  };
  db.prepare(
    `INSERT INTO runtime_sessions (id, agent_id, conversation_id, runtime_binding_id, status, created_at, updated_at)
     VALUES (@id, @agent_id, @conversation_id, @runtime_binding_id, @status, @created_at, @updated_at)`
  ).run(row);
  return rowToRuntimeSession(row);
}

export function getRuntimeSession(db: Database.Database, id: string): RuntimeSession | undefined {
  const row = db.prepare('SELECT * FROM runtime_sessions WHERE id = ?').get(id) as RuntimeSessionRow | undefined;
  return row ? rowToRuntimeSession(row) : undefined;
}

export function updateRuntimeSessionStatus(
  db: Database.Database,
  id: string,
  status: RuntimeSessionStatus
): RuntimeSession | undefined {
  db.prepare('UPDATE runtime_sessions SET status = ?, updated_at = ? WHERE id = ?').run(
    status,
    new Date().toISOString(),
    id
  );
  return getRuntimeSession(db, id);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/runtime/bindings.test.ts src/runtime/sessions.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0007_runtime_bindings.sql src/db/migrations/0008_runtime_sessions.sql src/runtime/bindings.ts src/runtime/bindings.test.ts src/runtime/sessions.ts src/runtime/sessions.test.ts
git commit -m "feat: add runtime binding and session persistence"
```

---

### Task 2: Agent run persistence with hop-count enforcement

**Files:**
- Create: `repos/server/src/db/migrations/0009_agent_runs.sql`
- Create: `repos/server/src/runtime/runs.ts`
- Test: `repos/server/src/runtime/runs.test.ts`

**Interfaces:**
- Consumes: `AgentRunSchema`, `AgentRun`, `DEFAULT_MAX_HOP_COUNT` from
  `@opencrew/protocol`. Test fixtures: `createUser`, `createAgent`,
  `createConversation` (existing repositories).
- Produces: `createAgentRun(db, { runId, rootRunId, causationId, hopCount,
  agentId, conversationId }): AgentRun`, `getAgentRun(db, runId): AgentRun |
  undefined`, `listAgentRunsForRoot(db, rootRunId): AgentRun[]` (ordered by
  `created_at ASC`). Task 3's engine builds directly on these.

- [ ] **Step 1: Write the failing test**

`repos/server/src/runtime/runs.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createAgentRun, getAgentRun, listAgentRunsForRoot } from './runs.js';

describe('agent runs repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithAgentAndConversation() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-runs-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: owner.id, participantType: 'user' },
        { participantId: agent.id, participantType: 'agent' },
      ],
    });
    return { db, agent, conversation };
  }

  it('creates a root run with hopCount 0 and reads it back', () => {
    const { db, agent, conversation } = freshDbWithAgentAndConversation();
    const runId = randomUUID();
    const run = createAgentRun(db, {
      runId,
      rootRunId: runId,
      causationId: null,
      hopCount: 0,
      agentId: agent.id,
      conversationId: conversation.id,
    });
    expect(run.hopCount).toBe(0);
    expect(getAgentRun(db, runId)?.runId).toBe(runId);
    db.close();
  });

  it('rejects a run with hopCount above DEFAULT_MAX_HOP_COUNT at the database layer', () => {
    const { db, agent, conversation } = freshDbWithAgentAndConversation();
    expect(() =>
      createAgentRun(db, {
        runId: randomUUID(),
        rootRunId: randomUUID(),
        causationId: null,
        hopCount: 5,
        agentId: agent.id,
        conversationId: conversation.id,
      })
    ).toThrow();
    db.close();
  });

  it('lists a run chain for a root in creation order', () => {
    const { db, agent, conversation } = freshDbWithAgentAndConversation();
    const rootRunId = randomUUID();
    createAgentRun(db, { runId: rootRunId, rootRunId, causationId: null, hopCount: 0, agentId: agent.id, conversationId: conversation.id });
    const hop1 = randomUUID();
    createAgentRun(db, { runId: hop1, rootRunId, causationId: rootRunId, hopCount: 1, agentId: agent.id, conversationId: conversation.id });

    const chain = listAgentRunsForRoot(db, rootRunId);
    expect(chain).toHaveLength(2);
    expect(chain[0].runId).toBe(rootRunId);
    expect(chain[1].runId).toBe(hop1);
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/runtime/runs.test.ts`
Expected: FAIL — module and table don't exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0009_agent_runs.sql`:
```sql
CREATE TABLE agent_runs (
  run_id TEXT PRIMARY KEY,
  root_run_id TEXT NOT NULL,
  causation_id TEXT,
  hop_count INTEGER NOT NULL CHECK (hop_count >= 0 AND hop_count <= 4),
  agent_id TEXT NOT NULL REFERENCES agents(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  created_at TEXT NOT NULL
);

CREATE INDEX idx_agent_runs_root ON agent_runs (root_run_id);
```

Note: `hop_count <= 4` hardcodes `@opencrew/protocol`'s `DEFAULT_MAX_HOP_COUNT`
— a migration can't reference a runtime constant. If that constant ever
changes, this migration's `CHECK` needs a follow-up migration too.

`repos/server/src/runtime/runs.ts`:
```ts
import { AgentRunSchema, type AgentRun } from '@opencrew/protocol';
import type Database from 'better-sqlite3';

interface AgentRunRow {
  run_id: string;
  root_run_id: string;
  causation_id: string | null;
  hop_count: number;
  agent_id: string;
  conversation_id: string;
  created_at: string;
}

function rowToAgentRun(row: AgentRunRow): AgentRun {
  return AgentRunSchema.parse({
    runId: row.run_id,
    rootRunId: row.root_run_id,
    causationId: row.causation_id,
    hopCount: row.hop_count,
    agentId: row.agent_id,
    conversationId: row.conversation_id,
    createdAt: row.created_at,
  });
}

export function createAgentRun(
  db: Database.Database,
  input: {
    runId: string;
    rootRunId: string;
    causationId: string | null;
    hopCount: number;
    agentId: string;
    conversationId: string;
  }
): AgentRun {
  const row: AgentRunRow = {
    run_id: input.runId,
    root_run_id: input.rootRunId,
    causation_id: input.causationId,
    hop_count: input.hopCount,
    agent_id: input.agentId,
    conversation_id: input.conversationId,
    created_at: new Date().toISOString(),
  };
  db.prepare(
    `INSERT INTO agent_runs (run_id, root_run_id, causation_id, hop_count, agent_id, conversation_id, created_at)
     VALUES (@run_id, @root_run_id, @causation_id, @hop_count, @agent_id, @conversation_id, @created_at)`
  ).run(row);
  return rowToAgentRun(row);
}

export function getAgentRun(db: Database.Database, runId: string): AgentRun | undefined {
  const row = db.prepare('SELECT * FROM agent_runs WHERE run_id = ?').get(runId) as AgentRunRow | undefined;
  return row ? rowToAgentRun(row) : undefined;
}

export function listAgentRunsForRoot(db: Database.Database, rootRunId: string): AgentRun[] {
  const rows = db
    .prepare('SELECT * FROM agent_runs WHERE root_run_id = ? ORDER BY created_at ASC')
    .all(rootRunId) as AgentRunRow[];
  return rows.map(rowToAgentRun);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/runtime/runs.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0009_agent_runs.sql src/runtime/runs.ts src/runtime/runs.test.ts
git commit -m "feat: add agent run persistence with DB-level hop-count enforcement"
```

---

### Task 3: Runtime engine — single-turn agent invocation

**Files:**
- Create: `repos/server/src/runtime/engine.ts`
- Test: `repos/server/src/runtime/engine.test.ts`

**Interfaces:**
- Consumes: `createAgentRun` from Task 2. `createMessage`,
  `listMessagesForConversation` from `../messages/repository.js`.
  `ConnectionHub` from `../ws/hub.js`. `DEFAULT_MAX_HOP_COUNT`, `Message`,
  `AgentRun` from `@opencrew/protocol`.
- Produces: `interface AgentTurnResult { body: string; handoffToAgentId?:
  string }`. `type RespondFn = (input: { agentId: string; conversationId:
  string; recentMessages: Message[] }) => Promise<AgentTurnResult>`.
  `interface RunAgentTurnDeps { db: Database.Database; hub: ConnectionHub;
  respond: RespondFn }`. `interface RunAgentTurnInput { agentId: string;
  conversationId: string; rootRunId?: string; causationId?: string | null;
  hopCount?: number }`. `interface RunAgentTurnOutcome { run: AgentRun;
  message: Message; handoff: { attempted: boolean; dispatched: boolean;
  blockedReason?: 'max_hop_count_exceeded' } }`. `class
  MaxHopCountExceededError extends Error`. `runAgentTurn(deps, input):
  Promise<RunAgentTurnOutcome>`. `defaultRespond: RespondFn` — a
  deterministic stub used as the production default until the
  `server-providers` plan supplies a real implementation. Task 4 modifies
  this same file to add handoff dispatch; Task 6's routes and Task 7's e2e
  test consume `runAgentTurn`, `defaultRespond`, `MaxHopCountExceededError`,
  and the `RespondFn` type exactly as defined here.

This task deliberately does NOT implement handoff dispatch yet — Task 4 adds
it as a focused, separately-reviewable extension of the same function.

- [ ] **Step 1: Write the failing test**

`repos/server/src/runtime/engine.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createMessage } from '../messages/repository.js';
import { ConnectionHub } from '../ws/hub.js';
import { defaultRespond, runAgentTurn, type AgentTurnResult, type RespondFn } from './engine.js';
import { getAgentRun } from './runs.js';

describe('runAgentTurn (single turn, no handoff)', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshSetup() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-engine-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: owner.id, participantType: 'user' },
        { participantId: agent.id, participantType: 'agent' },
      ],
    });
    createMessage(db, {
      conversationId: conversation.id,
      authorId: owner.id,
      authorType: 'user',
      body: 'hello agent',
      mentions: [],
      replyToMessageId: null,
    });
    const hub = new ConnectionHub(db);
    return { db, agent, conversation, hub };
  }

  it('persists a run, calls respond with recent conversation context, and persists+publishes the response as an agent message', async () => {
    const { db, agent, conversation, hub } = freshSetup();
    const respond = vi.fn(async (_input: Parameters<RespondFn>[0]): Promise<AgentTurnResult> => ({ body: 'hello human' }));

    const outcome = await runAgentTurn(
      { db, hub, respond },
      { agentId: agent.id, conversationId: conversation.id }
    );

    expect(respond).toHaveBeenCalledOnce();
    const call = respond.mock.calls[0][0];
    expect(call.agentId).toBe(agent.id);
    expect(call.recentMessages).toHaveLength(1);
    expect(call.recentMessages[0].body).toBe('hello agent');

    expect(outcome.message.authorType).toBe('agent');
    expect(outcome.message.authorId).toBe(agent.id);
    expect(outcome.message.body).toBe('hello human');
    expect(outcome.run.hopCount).toBe(0);
    expect(outcome.handoff).toEqual({ attempted: false, dispatched: false });

    expect(getAgentRun(db, outcome.run.runId)?.runId).toBe(outcome.run.runId);
    db.close();
  });

  it('defaultRespond returns a deterministic stub response mentioning the agent', async () => {
    const result = await defaultRespond({ agentId: 'agent_1', conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toContain('agent_1');
    expect(result.handoffToAgentId).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/runtime/engine.test.ts`
Expected: FAIL — module does not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/runtime/engine.ts`:
```ts
import { DEFAULT_MAX_HOP_COUNT, type AgentRun, type Message } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { createMessage, listMessagesForConversation } from '../messages/repository.js';
import type { ConnectionHub } from '../ws/hub.js';
import { createAgentRun } from './runs.js';

export interface AgentTurnResult {
  body: string;
  handoffToAgentId?: string;
}

export type RespondFn = (input: {
  agentId: string;
  conversationId: string;
  recentMessages: Message[];
}) => Promise<AgentTurnResult>;

export interface RunAgentTurnDeps {
  db: Database.Database;
  hub: ConnectionHub;
  respond: RespondFn;
}

export interface RunAgentTurnInput {
  agentId: string;
  conversationId: string;
  rootRunId?: string;
  causationId?: string | null;
  hopCount?: number;
}

export interface RunAgentTurnOutcome {
  run: AgentRun;
  message: Message;
  handoff: { attempted: boolean; dispatched: boolean; blockedReason?: 'max_hop_count_exceeded' };
}

export class MaxHopCountExceededError extends Error {}

export const defaultRespond: RespondFn = async ({ agentId }) => ({
  body: `[stub] Agent ${agentId} has no configured provider yet.`,
});

export async function runAgentTurn(deps: RunAgentTurnDeps, input: RunAgentTurnInput): Promise<RunAgentTurnOutcome> {
  const hopCount = input.hopCount ?? 0;
  if (hopCount > DEFAULT_MAX_HOP_COUNT) {
    throw new MaxHopCountExceededError(
      `hopCount ${hopCount} exceeds DEFAULT_MAX_HOP_COUNT (${DEFAULT_MAX_HOP_COUNT})`
    );
  }

  const runId = randomUUID();
  const rootRunId = input.rootRunId ?? runId;
  const causationId = input.causationId ?? null;

  const run = createAgentRun(deps.db, {
    runId,
    rootRunId,
    causationId,
    hopCount,
    agentId: input.agentId,
    conversationId: input.conversationId,
  });

  const recentMessages = listMessagesForConversation(deps.db, input.conversationId, 20);
  const result = await deps.respond({
    agentId: input.agentId,
    conversationId: input.conversationId,
    recentMessages,
  });

  const message = createMessage(deps.db, {
    conversationId: input.conversationId,
    authorId: input.agentId,
    authorType: 'agent',
    body: result.body,
    mentions: [],
    replyToMessageId: null,
  });
  deps.hub.publish(`conversation:${input.conversationId}`, 'message.created', { ...message });

  return { run, message, handoff: { attempted: false, dispatched: false } };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/runtime/engine.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/runtime/engine.ts src/runtime/engine.test.ts
git commit -m "feat: add Native Agent runtime engine for single-turn invocation"
```

---

### Task 4: Agent-to-agent handoff with max-hop protection

**Files:**
- Modify: `repos/server/src/runtime/engine.ts`
- Test: `repos/server/src/runtime/engine.test.ts` (extend the existing file)

**Interfaces:**
- Consumes/Produces: extends `runAgentTurn` from Task 3 — same signature,
  same `RunAgentTurnOutcome` shape (the `handoff` field, previously always
  `{ attempted: false, dispatched: false }`, is now populated for real).
  `listAgentRunsForRoot` from `./runs.js` (new import, used only in this
  task's test to inspect a persisted chain).

- [ ] **Step 1: Write the failing test**

Add to the existing `repos/server/src/runtime/engine.test.ts` (add this
import alongside the existing ones):
```ts
import { getAgentRun, listAgentRunsForRoot } from './runs.js';
```
(This replaces the existing `import { getAgentRun } from './runs.js';` line
— just add `listAgentRunsForRoot` to it.)

Then add this test inside the existing `describe('runAgentTurn ...', ...)`
block, before its closing `});`:
```ts
  it('stops an agent-to-agent handoff chain at the max hop count instead of looping forever', async () => {
    const { db, agent, conversation, hub } = freshSetup();
    const selfHandoffRespond = vi.fn(
      async (): Promise<AgentTurnResult> => ({
        body: 'still thinking, handing off to myself',
        handoffToAgentId: agent.id,
      })
    );

    const outcome = await runAgentTurn(
      { db, hub, respond: selfHandoffRespond },
      { agentId: agent.id, conversationId: conversation.id }
    );

    const chain = listAgentRunsForRoot(db, outcome.run.rootRunId);
    expect(chain).toHaveLength(DEFAULT_MAX_HOP_COUNT + 1);
    expect(chain.map((r) => r.hopCount)).toEqual([0, 1, 2, 3, 4]);
    // 5 recursive calls each attempted a handoff; only the first 4 (hop 0-3)
    // could dispatch a follow-up (into hops 1-4); the hop-4 call's attempted
    // handoff to hop 5 was blocked, never persisted.
    expect(selfHandoffRespond).toHaveBeenCalledTimes(5);
    db.close();
  });
```

Also add `DEFAULT_MAX_HOP_COUNT` to this test file's import from
`@opencrew/protocol` (it's already imported in `engine.ts` but the test file
needs its own import too):
```ts
import { DEFAULT_MAX_HOP_COUNT } from '@opencrew/protocol';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/runtime/engine.test.ts`
Expected: FAIL — the chain has only 1 run (hop 0), since `engine.ts` doesn't
dispatch handoffs yet.

- [ ] **Step 3: Write minimal implementation**

Update `repos/server/src/runtime/engine.ts`'s `runAgentTurn` function: replace
the final `return { run, message, handoff: { attempted: false, dispatched:
false } };` line with:
```ts
  if (!result.handoffToAgentId) {
    return { run, message, handoff: { attempted: false, dispatched: false } };
  }

  const nextHopCount = hopCount + 1;
  if (nextHopCount > DEFAULT_MAX_HOP_COUNT) {
    return { run, message, handoff: { attempted: true, dispatched: false, blockedReason: 'max_hop_count_exceeded' } };
  }

  await runAgentTurn(deps, {
    agentId: result.handoffToAgentId,
    conversationId: input.conversationId,
    rootRunId,
    causationId: runId,
    hopCount: nextHopCount,
  });

  return { run, message, handoff: { attempted: true, dispatched: true } };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/runtime/engine.test.ts`
Expected: PASS (both the Task 3 test and this task's new test).

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/runtime/engine.ts src/runtime/engine.test.ts
git commit -m "feat: add agent-to-agent handoff with max-hop-count protection"
```

---

### Task 5: Approval persistence

**Files:**
- Create: `repos/server/src/db/migrations/0010_approvals.sql`
- Create: `repos/server/src/approvals/repository.ts`
- Test: `repos/server/src/approvals/repository.test.ts`

**Interfaces:**
- Consumes: `ApprovalRequestSchema`, `ApprovalRequest`, `ApprovalStatus`,
  `ApprovalDecision` from `@opencrew/protocol`. `createAgentRun` (test
  fixture) from `../runtime/runs.js`.
- Produces: `class ApprovalAlreadyResolvedError extends Error`,
  `createApproval(db, { runId, agentId, action, details }): ApprovalRequest`
  (status always starts `'pending'`), `getApproval(db, id): ApprovalRequest |
  undefined`, `listPendingApprovals(db): ApprovalRequest[]`,
  `resolveApproval(db, id, decision: 'approve' | 'deny'): ApprovalRequest`.

- [ ] **Step 1: Write the failing test**

`repos/server/src/approvals/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createAgentRun } from '../runtime/runs.js';
import { ApprovalAlreadyResolvedError, createApproval, getApproval, listPendingApprovals, resolveApproval } from './repository.js';

describe('approvals repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshSetup() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-approvals-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: owner.id, participantType: 'user' },
        { participantId: agent.id, participantType: 'agent' },
      ],
    });
    const runId = randomUUID();
    const run = createAgentRun(db, {
      runId,
      rootRunId: runId,
      causationId: null,
      hopCount: 0,
      agentId: agent.id,
      conversationId: conversation.id,
    });
    return { db, agent, run };
  }

  it('creates a pending approval and lists it', () => {
    const { db, agent, run } = freshSetup();
    const approval = createApproval(db, {
      runId: run.runId,
      agentId: agent.id,
      action: 'send_email',
      details: { to: 'user@example.com' },
    });
    expect(approval.status).toBe('pending');
    expect(listPendingApprovals(db)).toHaveLength(1);
    db.close();
  });

  it('resolves an approval as approved and sets resolvedAt', () => {
    const { db, agent, run } = freshSetup();
    const approval = createApproval(db, { runId: run.runId, agentId: agent.id, action: 'send_email', details: {} });
    const resolved = resolveApproval(db, approval.id, 'approve');
    expect(resolved.status).toBe('approved');
    expect(resolved.resolvedAt).not.toBeNull();
    expect(listPendingApprovals(db)).toHaveLength(0);
    db.close();
  });

  it('resolves an approval as denied', () => {
    const { db, agent, run } = freshSetup();
    const approval = createApproval(db, { runId: run.runId, agentId: agent.id, action: 'send_email', details: {} });
    const resolved = resolveApproval(db, approval.id, 'deny');
    expect(resolved.status).toBe('denied');
    db.close();
  });

  it('rejects resolving an already-resolved approval', () => {
    const { db, agent, run } = freshSetup();
    const approval = createApproval(db, { runId: run.runId, agentId: agent.id, action: 'send_email', details: {} });
    resolveApproval(db, approval.id, 'approve');
    expect(() => resolveApproval(db, approval.id, 'deny')).toThrow(ApprovalAlreadyResolvedError);
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/approvals/repository.test.ts`
Expected: FAIL — module and table don't exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0010_approvals.sql`:
```sql
CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES agent_runs(run_id),
  agent_id TEXT NOT NULL REFERENCES agents(id),
  action TEXT NOT NULL,
  details TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'denied', 'expired')),
  created_at TEXT NOT NULL,
  resolved_at TEXT
);

CREATE INDEX idx_approvals_status ON approvals (status);
```

`repos/server/src/approvals/repository.ts`:
```ts
import { ApprovalRequestSchema, type ApprovalRequest, type ApprovalStatus } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface ApprovalRow {
  id: string;
  run_id: string;
  agent_id: string;
  action: string;
  details: string;
  status: ApprovalStatus;
  created_at: string;
  resolved_at: string | null;
}

function rowToApproval(row: ApprovalRow): ApprovalRequest {
  return ApprovalRequestSchema.parse({
    id: row.id,
    runId: row.run_id,
    agentId: row.agent_id,
    action: row.action,
    details: JSON.parse(row.details),
    status: row.status,
    createdAt: row.created_at,
    resolvedAt: row.resolved_at,
  });
}

export class ApprovalAlreadyResolvedError extends Error {}

export function createApproval(
  db: Database.Database,
  input: { runId: string; agentId: string; action: string; details: Record<string, unknown> }
): ApprovalRequest {
  const row: ApprovalRow = {
    id: randomUUID(),
    run_id: input.runId,
    agent_id: input.agentId,
    action: input.action,
    details: JSON.stringify(input.details),
    status: 'pending',
    created_at: new Date().toISOString(),
    resolved_at: null,
  };
  db.prepare(
    `INSERT INTO approvals (id, run_id, agent_id, action, details, status, created_at, resolved_at)
     VALUES (@id, @run_id, @agent_id, @action, @details, @status, @created_at, @resolved_at)`
  ).run(row);
  return rowToApproval(row);
}

export function getApproval(db: Database.Database, id: string): ApprovalRequest | undefined {
  const row = db.prepare('SELECT * FROM approvals WHERE id = ?').get(id) as ApprovalRow | undefined;
  return row ? rowToApproval(row) : undefined;
}

export function listPendingApprovals(db: Database.Database): ApprovalRequest[] {
  const rows = db
    .prepare("SELECT * FROM approvals WHERE status = 'pending' ORDER BY created_at ASC")
    .all() as ApprovalRow[];
  return rows.map(rowToApproval);
}

export function resolveApproval(
  db: Database.Database,
  id: string,
  decision: 'approve' | 'deny'
): ApprovalRequest {
  const existing = getApproval(db, id);
  if (!existing) {
    throw new Error('approval_not_found');
  }
  if (existing.status !== 'pending') {
    throw new ApprovalAlreadyResolvedError(`approval ${id} already resolved with status ${existing.status}`);
  }
  const status: ApprovalStatus = decision === 'approve' ? 'approved' : 'denied';
  db.prepare('UPDATE approvals SET status = ?, resolved_at = ? WHERE id = ?').run(
    status,
    new Date().toISOString(),
    id
  );
  return getApproval(db, id)!;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/approvals/repository.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0010_approvals.sql src/approvals/repository.ts src/approvals/repository.test.ts
git commit -m "feat: add approval persistence"
```

---

### Task 6: Runtime and approval REST routes, app.ts wiring

**Files:**
- Create: `repos/server/src/runtime/routes.ts`
- Test: `repos/server/src/runtime/routes.test.ts`
- Create: `repos/server/src/approvals/routes.ts`
- Test: `repos/server/src/approvals/routes.test.ts`
- Modify: `repos/server/src/app.ts`

**Interfaces:**
- Consumes: `createRuntimeBinding`, `getRuntimeBinding` from
  `./bindings.js`; `createRuntimeSession`, `getRuntimeSession` from
  `./sessions.js`; `runAgentTurn`, `MaxHopCountExceededError`, `RespondFn`
  from `./engine.js`; `getAgent` from `../agents/repository.js`;
  `requireAuth` from `../auth/middleware.js`. `listPendingApprovals`,
  `resolveApproval`, `ApprovalAlreadyResolvedError`, `getApproval` from
  `../approvals/repository.js`.
- Produces: `registerRuntimeRoutes(app: FastifyInstance, hub: ConnectionHub,
  respond: RespondFn): void` adding `POST /api/runtime-bindings`,
  `GET /api/runtime-bindings/:id`, `POST /api/runtime-sessions`,
  `GET /api/runtime-sessions/:id`, `POST /api/agents/:id/runs`.
  `registerApprovalRoutes(app: FastifyInstance): void` adding
  `GET /api/approvals`, `POST /api/approvals/:id/respond`. `BuildAppOptions`
  gains an optional `respond?: RespondFn` field (defaults to
  `defaultRespond` from Task 3) — this is the seam the `server-providers`
  plan will use to supply a real implementation without touching this file
  again beyond swapping the default.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/runtime/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';

describe('runtime routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupOwnerAndAgent(app: Awaited<ReturnType<typeof buildApp>>) {
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

  it('creates and reads back a runtime binding', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerAndAgent(app);

    const create = await app.inject({
      method: 'POST',
      url: '/api/runtime-bindings',
      headers: { authorization: `Bearer ${token}` },
      payload: { agentId, runtimeKind: 'native', workspacePath: '/workspaces/assistant' },
    });
    expect(create.statusCode).toBe(201);

    const get = await app.inject({
      method: 'GET',
      url: `/api/runtime-bindings/${create.json().id}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(get.json().workspacePath).toBe('/workspaces/assistant');

    await app.close();
  });

  it('creates and reads back a runtime session', async () => {
    const app = await buildApp({ db });
    const { token, agentId } = await setupOwnerAndAgent(app);

    const binding = await app.inject({
      method: 'POST',
      url: '/api/runtime-bindings',
      headers: { authorization: `Bearer ${token}` },
      payload: { agentId, runtimeKind: 'native', workspacePath: '/ws' },
    });
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: agentId, participantType: 'agent' },
    });

    const create = await app.inject({
      method: 'POST',
      url: '/api/runtime-sessions',
      headers: { authorization: `Bearer ${token}` },
      payload: { agentId, conversationId: dm.json().id, runtimeBindingId: binding.json().id },
    });
    expect(create.statusCode).toBe(201);

    const get = await app.inject({
      method: 'GET',
      url: `/api/runtime-sessions/${create.json().id}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(get.statusCode).toBe(200);
    expect(get.json().status).toBe('idle');

    await app.close();
  });

  it('invokes an agent and returns its persisted response message', async () => {
    const app = await buildApp({ db, respond: async ({ agentId }) => ({ body: `hi from ${agentId}` }) });
    const { token, agentId } = await setupOwnerAndAgent(app);
    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: agentId, participantType: 'agent' },
    });

    const invoke = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: { conversationId: dm.json().id },
    });
    expect(invoke.statusCode).toBe(201);
    expect(invoke.json().message.body).toBe(`hi from ${agentId}`);

    await app.close();
  });
});
```

`repos/server/src/approvals/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createAgentRun } from '../runtime/runs.js';
import { createApproval } from './repository.js';

describe('approval routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupPendingApproval() {
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: owner.id, participantType: 'user' },
        { participantId: agent.id, participantType: 'agent' },
      ],
    });
    const runId = randomUUID();
    const run = createAgentRun(db, {
      runId,
      rootRunId: runId,
      causationId: null,
      hopCount: 0,
      agentId: agent.id,
      conversationId: conversation.id,
    });
    const approval = createApproval(db, { runId: run.runId, agentId: agent.id, action: 'send_email', details: {} });
    return { owner, approval };
  }

  it('lists pending approvals and resolves one', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'admin@example.com', displayName: 'Admin', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const { approval } = await setupPendingApproval();

    const list = await app.inject({
      method: 'GET',
      url: '/api/approvals',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.json()).toHaveLength(1);

    const respond = await app.inject({
      method: 'POST',
      url: `/api/approvals/${approval.id}/respond`,
      headers: { authorization: `Bearer ${token}` },
      payload: { decision: 'approve' },
    });
    expect(respond.statusCode).toBe(200);
    expect(respond.json().status).toBe('approved');

    await app.close();
  });

  it('rejects responding to an already-resolved approval with 409', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'admin@example.com', displayName: 'Admin', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const { approval } = await setupPendingApproval();

    await app.inject({
      method: 'POST',
      url: `/api/approvals/${approval.id}/respond`,
      headers: { authorization: `Bearer ${token}` },
      payload: { decision: 'approve' },
    });
    const second = await app.inject({
      method: 'POST',
      url: `/api/approvals/${approval.id}/respond`,
      headers: { authorization: `Bearer ${token}` },
      payload: { decision: 'deny' },
    });
    expect(second.statusCode).toBe(409);

    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/runtime/routes.test.ts src/approvals/routes.test.ts`
Expected: FAIL — modules don't exist, routes return 404.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/runtime/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { getAgent } from '../agents/repository.js';
import { requireAuth } from '../auth/middleware.js';
import type { ConnectionHub } from '../ws/hub.js';
import { createRuntimeBinding, getRuntimeBinding } from './bindings.js';
import { MaxHopCountExceededError, runAgentTurn, type RespondFn } from './engine.js';
import { createRuntimeSession, getRuntimeSession } from './sessions.js';

const CreateBindingBodySchema = z.object({
  agentId: z.string().min(1),
  runtimeKind: z.enum(['native', 'claude-code', 'codex', 'gemini-cli']),
  workspacePath: z.string().min(1),
});

const CreateSessionBodySchema = z.object({
  agentId: z.string().min(1),
  conversationId: z.string().min(1),
  runtimeBindingId: z.string().min(1),
});

const InvokeAgentBodySchema = z.object({
  conversationId: z.string().min(1),
});

export function registerRuntimeRoutes(app: FastifyInstance, hub: ConnectionHub, respond: RespondFn): void {
  app.post('/api/runtime-bindings', { preHandler: requireAuth }, async (request, reply) => {
    const body = CreateBindingBodySchema.parse(request.body);
    if (!getAgent(app.db, body.agentId)) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    reply.code(201).send(createRuntimeBinding(app.db, body));
  });

  app.get('/api/runtime-bindings/:id', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const binding = getRuntimeBinding(app.db, id);
    if (!binding) {
      reply.code(404).send({ error: 'runtime_binding_not_found' });
      return;
    }
    reply.send(binding);
  });

  app.post('/api/runtime-sessions', { preHandler: requireAuth }, async (request, reply) => {
    const body = CreateSessionBodySchema.parse(request.body);
    if (!getRuntimeBinding(app.db, body.runtimeBindingId)) {
      reply.code(404).send({ error: 'runtime_binding_not_found' });
      return;
    }
    reply.code(201).send(createRuntimeSession(app.db, body));
  });

  app.get('/api/runtime-sessions/:id', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = getRuntimeSession(app.db, id);
    if (!session) {
      reply.code(404).send({ error: 'runtime_session_not_found' });
      return;
    }
    reply.send(session);
  });

  app.post('/api/agents/:id/runs', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!getAgent(app.db, id)) {
      reply.code(404).send({ error: 'agent_not_found' });
      return;
    }
    const body = InvokeAgentBodySchema.parse(request.body);
    try {
      const outcome = await runAgentTurn(
        { db: app.db, hub, respond },
        { agentId: id, conversationId: body.conversationId }
      );
      reply.code(201).send(outcome);
    } catch (err) {
      if (err instanceof MaxHopCountExceededError) {
        reply.code(400).send({ error: 'max_hop_count_exceeded' });
        return;
      }
      throw err;
    }
  });
}
```

`repos/server/src/approvals/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireAuth } from '../auth/middleware.js';
import { ApprovalAlreadyResolvedError, getApproval, listPendingApprovals, resolveApproval } from './repository.js';

const RespondBodySchema = z.object({
  decision: z.enum(['approve', 'deny']),
});

export function registerApprovalRoutes(app: FastifyInstance): void {
  app.get('/api/approvals', { preHandler: requireAuth }, async (_request, reply) => {
    reply.send(listPendingApprovals(app.db));
  });

  app.post('/api/approvals/:id/respond', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!getApproval(app.db, id)) {
      reply.code(404).send({ error: 'approval_not_found' });
      return;
    }
    const body = RespondBodySchema.parse(request.body);
    try {
      reply.send(resolveApproval(app.db, id, body.decision));
    } catch (err) {
      if (err instanceof ApprovalAlreadyResolvedError) {
        reply.code(409).send({ error: 'already_resolved' });
        return;
      }
      throw err;
    }
  });
}
```

Update `repos/server/src/app.ts`:
```ts
import websocketPlugin from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { ZodError } from 'zod';
import { registerAgentRoutes } from './agents/routes.js';
import { registerApprovalRoutes } from './approvals/routes.js';
import { registerAuthRoutes } from './auth/routes.js';
import { registerConversationRoutes } from './conversations/routes.js';
import { registerMessageRoutes } from './messages/routes.js';
import { defaultRespond, type RespondFn } from './runtime/engine.js';
import { registerRuntimeRoutes } from './runtime/routes.js';
import { ConnectionHub } from './ws/hub.js';
import { registerWsRoutes } from './ws/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
  respond?: RespondFn;
}

export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  app.decorate('db', opts.db);
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ZodError) {
      reply.code(400).send({ error: 'invalid_request', issues: error.issues });
      return;
    }
    reply.send(error);
  });
  const hub = new ConnectionHub(opts.db);
  app.decorate('hub', hub);
  await app.register(websocketPlugin);

  app.get('/api/health', async () => ({ ok: true }));
  registerAuthRoutes(app);
  registerAgentRoutes(app);
  registerConversationRoutes(app);
  registerMessageRoutes(app, hub);
  registerRuntimeRoutes(app, hub, opts.respond ?? defaultRespond);
  registerApprovalRoutes(app);
  registerWsRoutes(app, hub);

  return app;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/runtime/routes.test.ts src/approvals/routes.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/runtime/routes.ts src/runtime/routes.test.ts src/approvals/routes.ts src/approvals/routes.test.ts src/app.ts
git commit -m "feat: add runtime and approval REST routes, wire respond seam into buildApp"
```

---

### Task 7: End-to-end proof — agent invocation, WS delivery, and max-hop protection through the full stack

**Files:**
- Create: `repos/server/test/runtime-e2e.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1-6 (`buildApp` with an injected
  `respond`, runtime/approval routes, `/ws`). No new production code — this
  is the charter's explicit testing minimums (agent invocation, max-hop
  protection, runtime binding persistence) proven together against a real
  HTTP+WebSocket server, the same way `test/messaging-e2e.test.ts` proved
  the messaging-core plan's minimums.

- [ ] **Step 1: Write the test**

`repos/server/test/runtime-e2e.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { buildApp } from '../src/app.js';
import { runMigrations } from '../src/db/migrate.js';
import type { AgentTurnResult, RespondFn } from '../src/runtime/engine.js';

describe('runtime end-to-end: agent invocation, WS delivery, and max-hop protection', () => {
  let db: Database.Database;
  let app: Awaited<ReturnType<typeof buildApp>>;
  let baseUrl: string;
  let loopingAgentId = '';

  const respond: RespondFn = async (input): Promise<AgentTurnResult> => {
    if (input.agentId === loopingAgentId) {
      return { body: 'still thinking, handing off to myself', handoffToAgentId: loopingAgentId };
    }
    return { body: 'Hello from the agent!' };
  };

  beforeEach(async () => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
    app = await buildApp({ db, respond });
    await app.listen({ port: 0, host: '127.0.0.1' });
    const address = app.server.address();
    if (typeof address === 'string' || address === null) throw new Error('expected AddressInfo');
    baseUrl = `127.0.0.1:${address.port}`;
  });

  afterEach(async () => {
    await app.close();
    db.close();
  });

  function waitForMessage(socket: WebSocket): Promise<Record<string, unknown>> {
    return new Promise((resolve) => {
      socket.once('message', (data) => resolve(JSON.parse(data.toString())));
    });
  }

  function waitForOpen(socket: WebSocket): Promise<void> {
    return new Promise((resolve) => socket.once('open', () => resolve()));
  }

  it('invokes an agent via REST, persists its response, and delivers it live over WebSocket', async () => {
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

    const binding = await app.inject({
      method: 'POST',
      url: '/api/runtime-bindings',
      headers: { authorization: `Bearer ${token}` },
      payload: { agentId, runtimeKind: 'native', workspacePath: '/workspaces/assistant' },
    });
    expect(binding.statusCode).toBe(201);

    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: agentId, participantType: 'agent' },
    });
    expect(dm.statusCode).toBe(201);
    const conversationId = dm.json().id as string;

    const socket = new WebSocket(`ws://${baseUrl}/ws?token=${token}`);
    await waitForOpen(socket);

    const messagePromise = waitForMessage(socket);
    const invoke = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: { conversationId },
    });
    expect(invoke.statusCode).toBe(201);
    expect(invoke.json().message.body).toBe('Hello from the agent!');

    const received = await messagePromise;
    expect(received.type).toBe('message.created');
    expect((received.payload as { body: string }).body).toBe('Hello from the agent!');
    socket.close();
  });

  it('stops an agent-to-agent handoff chain at the max hop count instead of looping forever', async () => {
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
      payload: { name: 'Looper', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' } },
    });
    loopingAgentId = createAgent.json().id as string;

    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: loopingAgentId, participantType: 'agent' },
    });
    const conversationId = dm.json().id as string;

    const invoke = await app.inject({
      method: 'POST',
      url: `/api/agents/${loopingAgentId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: { conversationId },
    });
    expect(invoke.statusCode).toBe(201);

    const messages = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(messages.json()).toHaveLength(5);
  });
});
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd repos/server && npx vitest run test/runtime-e2e.test.ts`
Expected: at this point in the plan (after Tasks 1-6) this should PASS
immediately, since every piece it exercises was already built and tested in
isolation by earlier tasks — this task's job is proving they integrate
correctly together end-to-end over real HTTP and WebSocket connections. If
it fails, that reveals an integration gap between two "complete" earlier
tasks; fix the bug in whichever task's files are implicated, re-run that
task's own test file to confirm no regression, then re-run this test.

- [ ] **Step 3: Run the full suite, tsc, and the build to verify the whole plan is sound**

```bash
cd repos/server
npm test
npx tsc -p tsconfig.json --noEmit
npm run build
```

Expected: every test file passes, `tsc --noEmit` is clean (this now
type-checks both `src/**/*.test.ts` and `test/`, per the messaging-core
plan's fix), `npm run build` succeeds with no TypeScript errors, and
`dist/` contains no `.test.js`/`.test.d.ts` files and all 10 migrations.

- [ ] **Step 4: Commit**

```bash
cd repos/server
git add test/runtime-e2e.test.ts
git commit -m "test: prove agent invocation, WS delivery, and max-hop protection end-to-end"
```

---

## What this plan deliberately leaves out

- **agentd integration.** agentd (repos/agentd) doesn't exist in this
  workspace yet — it's Developer B's responsibility. This plan's Native
  Agent runtime is entirely in-process; the `claude-code`/`codex`/
  `gemini-cli` values in `RuntimeKindSchema` remain valid to *store* (a
  `RuntimeBinding` can be created with any of them) but nothing in this plan
  ever *dispatches* to them. **DEV B REQUEST** (not yet needed, noted for
  when agentd exists): the server will need an agentd client module that
  sends exactly the six named operations (`runtime.run`, `runtime.resume`,
  `provider.chat`, `provider.models`, `workspace.list`, `approval.respond`)
  over whatever transport agentd exposes (the protocol package's
  `AgentdRequestSchema`/`AgentdResponseSchema`/`AgentdEventSchema` already
  define the wire shape) — that's a future plan's task, not this one's.
- **Real LLM providers.** `RespondFn` is the seam; `defaultRespond` is a
  stub. The `server-providers` plan supplies Anthropic/OpenAI/OpenRouter/
  DeepSeek/Claude-Subscription/Ollama-backed implementations later.
- **Mention-triggered auto-invocation.** In this plan, an agent only runs
  when explicitly invoked via `POST /api/agents/:id/runs`. Automatically
  triggering an agent when a message `@mentions` it (using the `mentions`
  field messages already carry) is a reasonable next step but wasn't asked
  for here and would require deciding trigger semantics (every mention?
  only in conversations the agent already participates in? debounced?) that
  belong in front of a real provider, not a stub one.
- **Per-conversation runtime session lifecycle wiring.** `RuntimeSession`
  status transitions (`idle` → `running` → `waiting_approval` → `closed`)
  are persisted and updatable via `updateRuntimeSessionStatus`, but
  `runAgentTurn` doesn't yet update a session's status as it runs — it
  operates directly against `agent_runs`. Wiring a `RuntimeSession` into
  the turn lifecycle (so `waiting_approval` blocks on an `ApprovalRequest`
  resolving) is real work for whichever plan makes approvals load-bearing
  rather than a standalone CRUD resource.
- **Provider failure handling, memory persistence** — separate,
  not-yet-written charter plans (`server-providers`,
  `server-memory-and-jobs`).
