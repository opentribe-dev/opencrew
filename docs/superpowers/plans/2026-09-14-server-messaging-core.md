# Server Messaging Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add conversations (DM/group), messages, mentions, replies, and group
membership management to `@opencrew/server`, wired onto the existing
`ConnectionHub` so message delivery and reconnect/replay work over real
per-conversation WebSocket topics, not just the single `user:<id>` topic that
exists today.

**Architecture:** Two new domain modules (`conversations/`, `messages/`)
follow the exact repository+routes pattern already established by
`agents/`: a `*Schema.parse(...)`-validated repository over raw SQL, thin
Fastify routes behind `requireAuth`. Messages are persisted to the `messages`
table first, then published via the existing `ConnectionHub.publish()` to a
`conversation:<id>` topic — the same persist-before-broadcast guarantee
`user:<id>` events already have. `/ws` is extended to subscribe each
connection to every conversation topic the user is currently a participant
of, computed once at connect time.

**Tech Stack:** Same as `@opencrew/server` — Fastify 5, better-sqlite3,
`@opencrew/protocol`, Zod, Vitest 2. No new dependencies.

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- One server process, one exposed port, one persistent data directory,
  SQLite+WAL — no external services.
- Messages must be persisted before realtime broadcast; WebSocket is
  transport, not source of truth (already true for `ConnectionHub.publish`;
  this plan's job is to route real conversation traffic through it).
- Reconnect/replay uses the existing sequence mechanism (`event_log.seq`
  via `ConnectionHub.replaySince`) — no new replay mechanism, just more topics.
- Untested work must not be reported as completed.
- Agent-to-agent messaging, the Native Agent runtime, and per-conversation
  hop-count limits are OUT OF SCOPE for this plan (a separate,
  not-yet-written `server-runtime-and-agent-to-agent` plan). This plan only
  builds the conversation/message persistence and delivery layer those
  features will sit on top of.

## Prerequisite

`repos/server` is on `main` at commit `adc4d10` (server-foundations plan,
merged) and `repos/protocol` is on `main` at commit `901ad05`
(protocol-foundations plan, merged). Both already exist and build. This plan
works directly on `repos/server`'s `main` branch via a new feature branch.

---

## File Structure

```
repos/server/
  tsconfig.json                          # modified: exclude test files from dist
  src/
    app.ts                               # modified: register conversation/message routes
    ws/
      routes.ts                          # modified: subscribe to conversation topics too
    db/
      migrations/
        0005_conversations.sql
        0006_messages.sql
    conversations/
      repository.ts
      repository.test.ts
      routes.ts
      routes.test.ts
    messages/
      repository.ts
      repository.test.ts
      routes.ts
      routes.test.ts
  test/
    messaging-e2e.test.ts                # full WS delivery + reconnect/replay proof
```

---

### Task 1: Conversations table and repository (+ tsconfig test-exclude fix)

**Files:**
- Create: `repos/server/src/db/migrations/0005_conversations.sql`
- Create: `repos/server/src/conversations/repository.ts`
- Test: `repos/server/src/conversations/repository.test.ts`
- Modify: `repos/server/tsconfig.json`

**Interfaces:**
- Consumes: `ConversationSchema`, `Conversation`, `ParticipantRef`,
  `ActorType` from `@opencrew/protocol` (already published, no change
  needed there).
- Produces: `createConversation(db, { kind: 'dm' | 'group'; name: string |
  null; participants: ParticipantRef[] }): Conversation`,
  `getConversation(db, id: string): Conversation | undefined`,
  `isParticipant(db, conversationId: string, participantId: string,
  participantType: ActorType): boolean`,
  `listConversationsForParticipant(db, participantId: string):
  Conversation[]`, `addParticipant(db, conversationId: string, participant:
  ParticipantRef): void`, `removeParticipant(db, conversationId: string,
  participantId: string): void`. Every later task in this plan builds on
  these exact names and signatures.

Folds in a small, unrelated-but-cheap fix carried forward from the
server-foundations plan's final review: `tsconfig.json` has no `exclude` for
test files, so `dist/` ships compiled `*.test.js`/`.test.d.ts` (the protocol
package already has this exclude; server never got it). Doing it here since
this is the next task touching server config.

- [ ] **Step 1: Write the failing test**

`repos/server/src/conversations/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import {
  addParticipant,
  createConversation,
  getConversation,
  isParticipant,
  listConversationsForParticipant,
  removeParticipant,
} from './repository.js';

describe('conversations repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithTwoUsers() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-conversations-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const alice = createUser(db, { email: 'alice@example.com', displayName: 'Alice', passwordHash: 'x', role: 'owner' });
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'y', role: 'member' });
    return { db, alice, bob };
  }

  it('creates a dm with exactly two participants and reads it back', () => {
    const { db, alice, bob } = freshDbWithTwoUsers();
    const dm = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    expect(dm.kind).toBe('dm');
    expect(dm.participants).toHaveLength(2);
    expect(getConversation(db, dm.id)?.id).toBe(dm.id);
    db.close();
  });

  it('creates a named group conversation', () => {
    const { db, alice, bob } = freshDbWithTwoUsers();
    const group = createConversation(db, {
      kind: 'group',
      name: 'Launch planning',
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    expect(group.name).toBe('Launch planning');
    db.close();
  });

  it('reports isParticipant correctly and lists conversations for a participant', () => {
    const { db, alice, bob } = freshDbWithTwoUsers();
    const dm = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    expect(isParticipant(db, dm.id, alice.id, 'user')).toBe(true);
    expect(isParticipant(db, dm.id, 'nonexistent-user', 'user')).toBe(false);

    const aliceConversations = listConversationsForParticipant(db, alice.id);
    expect(aliceConversations).toHaveLength(1);
    expect(aliceConversations[0].id).toBe(dm.id);
    db.close();
  });

  it('adds and removes a participant from a group', () => {
    const { db, alice, bob } = freshDbWithTwoUsers();
    const carol = createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'z', role: 'member' });
    const group = createConversation(db, {
      kind: 'group',
      name: 'Team',
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    addParticipant(db, group.id, { participantId: carol.id, participantType: 'user' });
    expect(isParticipant(db, group.id, carol.id, 'user')).toBe(true);

    removeParticipant(db, group.id, carol.id);
    expect(isParticipant(db, group.id, carol.id, 'user')).toBe(false);
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/conversations/repository.test.ts`
Expected: FAIL — `./repository.js` does not exist, and the `conversations`/
`conversation_participants` tables don't exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0005_conversations.sql`:
```sql
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('dm', 'group')),
  name TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE conversation_participants (
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  participant_id TEXT NOT NULL,
  participant_type TEXT NOT NULL CHECK (participant_type IN ('user', 'agent')),
  added_at TEXT NOT NULL,
  PRIMARY KEY (conversation_id, participant_id, participant_type)
);

CREATE INDEX idx_conversation_participants_participant
  ON conversation_participants (participant_id, participant_type);
```

`repos/server/src/conversations/repository.ts`:
```ts
import { ConversationSchema, type ActorType, type Conversation, type ParticipantRef } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface ConversationRow {
  id: string;
  kind: 'dm' | 'group';
  name: string | null;
  created_at: string;
  updated_at: string;
}

interface ParticipantRow {
  conversation_id: string;
  participant_id: string;
  participant_type: ActorType;
  added_at: string;
}

function getParticipants(db: Database.Database, conversationId: string): ParticipantRef[] {
  const rows = db
    .prepare('SELECT * FROM conversation_participants WHERE conversation_id = ?')
    .all(conversationId) as ParticipantRow[];
  return rows.map((r) => ({ participantId: r.participant_id, participantType: r.participant_type }));
}

function rowToConversation(row: ConversationRow, participants: ParticipantRef[]): Conversation {
  return ConversationSchema.parse({
    id: row.id,
    kind: row.kind,
    name: row.name,
    participants,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

export function createConversation(
  db: Database.Database,
  input: { kind: 'dm' | 'group'; name: string | null; participants: ParticipantRef[] }
): Conversation {
  const now = new Date().toISOString();
  const row: ConversationRow = {
    id: randomUUID(),
    kind: input.kind,
    name: input.name,
    created_at: now,
    updated_at: now,
  };
  const insertConversation = db.prepare(
    `INSERT INTO conversations (id, kind, name, created_at, updated_at)
     VALUES (@id, @kind, @name, @created_at, @updated_at)`
  );
  const insertParticipant = db.prepare(
    `INSERT INTO conversation_participants (conversation_id, participant_id, participant_type, added_at)
     VALUES (?, ?, ?, ?)`
  );
  const createTx = db.transaction(() => {
    insertConversation.run(row);
    for (const p of input.participants) {
      insertParticipant.run(row.id, p.participantId, p.participantType, now);
    }
  });
  createTx();
  return rowToConversation(row, input.participants);
}

export function getConversation(db: Database.Database, id: string): Conversation | undefined {
  const row = db.prepare('SELECT * FROM conversations WHERE id = ?').get(id) as ConversationRow | undefined;
  if (!row) return undefined;
  return rowToConversation(row, getParticipants(db, id));
}

export function isParticipant(
  db: Database.Database,
  conversationId: string,
  participantId: string,
  participantType: ActorType
): boolean {
  const row = db
    .prepare(
      'SELECT 1 FROM conversation_participants WHERE conversation_id = ? AND participant_id = ? AND participant_type = ?'
    )
    .get(conversationId, participantId, participantType);
  return row !== undefined;
}

export function listConversationsForParticipant(db: Database.Database, participantId: string): Conversation[] {
  const rows = db
    .prepare(
      `SELECT c.* FROM conversations c
       JOIN conversation_participants cp ON cp.conversation_id = c.id
       WHERE cp.participant_id = ?
       ORDER BY c.updated_at DESC`
    )
    .all(participantId) as ConversationRow[];
  return rows.map((row) => rowToConversation(row, getParticipants(db, row.id)));
}

export function addParticipant(db: Database.Database, conversationId: string, participant: ParticipantRef): void {
  db.prepare(
    `INSERT INTO conversation_participants (conversation_id, participant_id, participant_type, added_at)
     VALUES (?, ?, ?, ?)`
  ).run(conversationId, participant.participantId, participant.participantType, new Date().toISOString());
}

export function removeParticipant(db: Database.Database, conversationId: string, participantId: string): void {
  db.prepare('DELETE FROM conversation_participants WHERE conversation_id = ? AND participant_id = ?').run(
    conversationId,
    participantId
  );
}
```

Update `repos/server/tsconfig.json` to add the `exclude` key (new key,
alongside existing `compilerOptions`/`include`):
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "declaration": true,
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "types": ["node"]
  },
  "include": ["src"],
  "exclude": ["src/**/*.test.ts"]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/conversations/repository.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0005_conversations.sql src/conversations/repository.ts src/conversations/repository.test.ts tsconfig.json
git commit -m "feat: add conversations table and repository"
```

---

### Task 2: Conversation REST routes (DM and group creation, listing)

**Files:**
- Create: `repos/server/src/conversations/routes.ts`
- Test: `repos/server/src/conversations/routes.test.ts`
- Modify: `repos/server/src/app.ts`

**Interfaces:**
- Consumes: `createConversation`, `listConversationsForParticipant` from
  Task 1. `can`/`Role` from `../permissions/model.js`. `getUserById` from
  `../users/repository.js`. `getAgent` from `../agents/repository.js`.
  `requireAuth` from `../auth/middleware.js`.
- Produces: `registerConversationRoutes(app: FastifyInstance): void` adding
  `POST /api/conversations` (dm), `POST /api/conversations/group`,
  `GET /api/conversations` — all behind `requireAuth`. Also produces an
  internal `participantExists` helper Task 6 (in the same file) reuses.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/conversations/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';
import { createSession } from '../auth/session.js';
import { createUser } from '../users/repository.js';

describe('conversation routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupOwner(app: Awaited<ReturnType<typeof buildApp>>) {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    return { token: setup.json().token as string, userId: setup.json().user.id as string };
  }

  it('creates a dm with an existing user and lists it back', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });

    const create = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: bob.id, participantType: 'user' },
    });
    expect(create.statusCode).toBe(201);
    expect(create.json().kind).toBe('dm');
    expect(create.json().participants).toHaveLength(2);

    const list = await app.inject({
      method: 'GET',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toHaveLength(1);

    await app.close();
  });

  it('rejects a dm with a nonexistent participant', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);

    const create = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: 'nonexistent', participantType: 'user' },
    });
    expect(create.statusCode).toBe(404);

    await app.close();
  });

  it('creates a named group with multiple participants', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const carol = createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'y', role: 'member' });

    const create = await app.inject({
      method: 'POST',
      url: '/api/conversations/group',
      headers: { authorization: `Bearer ${token}` },
      payload: {
        name: 'Team',
        participants: [
          { participantId: bob.id, participantType: 'user' },
          { participantId: carol.id, participantType: 'user' },
        ],
      },
    });
    expect(create.statusCode).toBe(201);
    expect(create.json().name).toBe('Team');
    expect(create.json().participants).toHaveLength(3);

    await app.close();
  });

  it('rejects conversation creation without authentication', async () => {
    const app = await buildApp({ db });
    const response = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      payload: { participantId: 'anyone', participantType: 'user' },
    });
    expect(response.statusCode).toBe(401);
    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/conversations/routes.test.ts`
Expected: FAIL — `./routes.js` doesn't exist, `/api/conversations` returns 404.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/conversations/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { getAgent } from '../agents/repository.js';
import { requireAuth } from '../auth/middleware.js';
import { can, type Role } from '../permissions/model.js';
import { getUserById } from '../users/repository.js';
import { createConversation, listConversationsForParticipant } from './repository.js';

const CreateDmBodySchema = z.object({
  participantId: z.string().min(1),
  participantType: z.enum(['user', 'agent']).default('user'),
});

const CreateGroupBodySchema = z.object({
  name: z.string().min(1),
  participants: z
    .array(z.object({ participantId: z.string().min(1), participantType: z.enum(['user', 'agent']) }))
    .min(1),
});

function participantExists(
  app: FastifyInstance,
  participantId: string,
  participantType: 'user' | 'agent'
): boolean {
  if (participantType === 'user') return getUserById(app.db, participantId) !== undefined;
  return getAgent(app.db, participantId) !== undefined;
}

export function registerConversationRoutes(app: FastifyInstance): void {
  app.post('/api/conversations', { preHandler: requireAuth }, async (request, reply) => {
    const body = CreateDmBodySchema.parse(request.body);
    if (!participantExists(app, body.participantId, body.participantType)) {
      reply.code(404).send({ error: 'participant_not_found' });
      return;
    }
    const conversation = createConversation(app.db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: request.user!.id, participantType: 'user' },
        { participantId: body.participantId, participantType: body.participantType },
      ],
    });
    reply.code(201).send(conversation);
  });

  app.post('/api/conversations/group', { preHandler: requireAuth }, async (request, reply) => {
    if (!can(request.user!.role as Role, 'conversation:create_group')) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const body = CreateGroupBodySchema.parse(request.body);
    for (const p of body.participants) {
      if (!participantExists(app, p.participantId, p.participantType)) {
        reply.code(404).send({ error: 'participant_not_found' });
        return;
      }
    }
    const conversation = createConversation(app.db, {
      kind: 'group',
      name: body.name,
      participants: [{ participantId: request.user!.id, participantType: 'user' }, ...body.participants],
    });
    reply.code(201).send(conversation);
  });

  app.get('/api/conversations', { preHandler: requireAuth }, async (request, reply) => {
    reply.send(listConversationsForParticipant(app.db, request.user!.id));
  });
}
```

Note: `participantExists` is intentionally unexported — Task 6 modifies this
same file and can reference it directly without an import.

Update `repos/server/src/app.ts`:
```ts
import websocketPlugin from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { ZodError } from 'zod';
import { registerAgentRoutes } from './agents/routes.js';
import { registerAuthRoutes } from './auth/routes.js';
import { registerConversationRoutes } from './conversations/routes.js';
import { ConnectionHub } from './ws/hub.js';
import { registerWsRoutes } from './ws/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
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
  registerWsRoutes(app, hub);

  return app;
}
```

(Task 4 below adds `registerMessageRoutes(app, hub)` to this same file — one
more line, shown in that task.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/conversations/routes.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/conversations/routes.ts src/conversations/routes.test.ts src/app.ts
git commit -m "feat: add conversation REST routes (dm, group, list)"
```

---

### Task 3: Messages table and repository

**Files:**
- Create: `repos/server/src/db/migrations/0006_messages.sql`
- Create: `repos/server/src/messages/repository.ts`
- Test: `repos/server/src/messages/repository.test.ts`

**Interfaces:**
- Consumes: `MessageSchema`, `Message`, `MentionRef`, `ActorType` from
  `@opencrew/protocol`.
- Produces: `class ReplyNotInConversationError extends Error`,
  `createMessage(db, { conversationId: string; authorId: string; authorType:
  ActorType; body: string; mentions: MentionRef[]; replyToMessageId: string |
  null }): Message`, `listMessagesForConversation(db, conversationId: string,
  limit?: number): Message[]` (ordered oldest-first, default limit 50).

- [ ] **Step 1: Write the failing test**

`repos/server/src/messages/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createConversation } from '../conversations/repository.js';
import { createMessage, listMessagesForConversation, ReplyNotInConversationError } from './repository.js';

describe('messages repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithConversation() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-messages-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const alice = createUser(db, { email: 'alice@example.com', displayName: 'Alice', passwordHash: 'x', role: 'owner' });
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'y', role: 'member' });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    return { db, alice, bob, conversation };
  }

  it('creates a message with a mention and reads it back in order', () => {
    const { db, alice, bob, conversation } = freshDbWithConversation();
    const message = createMessage(db, {
      conversationId: conversation.id,
      authorId: alice.id,
      authorType: 'user',
      body: `hey @${bob.displayName} following up`,
      mentions: [{ targetId: bob.id, targetType: 'user' }],
      replyToMessageId: null,
    });
    expect(message.mentions).toHaveLength(1);

    const list = listMessagesForConversation(db, conversation.id);
    expect(list).toHaveLength(1);
    expect(list[0].id).toBe(message.id);
    db.close();
  });

  it('accepts a reply to a message in the same conversation', () => {
    const { db, alice, conversation } = freshDbWithConversation();
    const first = createMessage(db, {
      conversationId: conversation.id,
      authorId: alice.id,
      authorType: 'user',
      body: 'first message',
      mentions: [],
      replyToMessageId: null,
    });
    const reply = createMessage(db, {
      conversationId: conversation.id,
      authorId: alice.id,
      authorType: 'user',
      body: 'a reply',
      mentions: [],
      replyToMessageId: first.id,
    });
    expect(reply.replyToMessageId).toBe(first.id);
    db.close();
  });

  it('rejects a reply that references a message from a different conversation', () => {
    const { db, alice, bob, conversation } = freshDbWithConversation();
    const otherConversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: alice.id, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });
    const messageInOther = createMessage(db, {
      conversationId: otherConversation.id,
      authorId: alice.id,
      authorType: 'user',
      body: 'lives elsewhere',
      mentions: [],
      replyToMessageId: null,
    });
    expect(() =>
      createMessage(db, {
        conversationId: conversation.id,
        authorId: alice.id,
        authorType: 'user',
        body: 'wrong reply target',
        mentions: [],
        replyToMessageId: messageInOther.id,
      })
    ).toThrow(ReplyNotInConversationError);
    db.close();
  });

  it('orders messages oldest-first and respects the limit', () => {
    const { db, alice, conversation } = freshDbWithConversation();
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'one', mentions: [], replyToMessageId: null });
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'two', mentions: [], replyToMessageId: null });
    createMessage(db, { conversationId: conversation.id, authorId: alice.id, authorType: 'user', body: 'three', mentions: [], replyToMessageId: null });

    const limited = listMessagesForConversation(db, conversation.id, 2);
    expect(limited).toHaveLength(2);
    expect(limited[0].body).toBe('one');
    expect(limited[1].body).toBe('two');
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/messages/repository.test.ts`
Expected: FAIL — `./repository.js` does not exist, `messages` table doesn't exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0006_messages.sql`:
```sql
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  author_id TEXT NOT NULL,
  author_type TEXT NOT NULL CHECK (author_type IN ('user', 'agent')),
  body TEXT NOT NULL,
  reply_to_message_id TEXT REFERENCES messages(id),
  created_at TEXT NOT NULL
);

CREATE INDEX idx_messages_conversation_created ON messages (conversation_id, created_at);

CREATE TABLE message_mentions (
  message_id TEXT NOT NULL REFERENCES messages(id),
  target_id TEXT NOT NULL,
  target_type TEXT NOT NULL CHECK (target_type IN ('user', 'agent')),
  PRIMARY KEY (message_id, target_id, target_type)
);
```

`repos/server/src/messages/repository.ts`:
```ts
import { MessageSchema, type ActorType, type MentionRef, type Message } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface MessageRow {
  id: string;
  conversation_id: string;
  author_id: string;
  author_type: ActorType;
  body: string;
  reply_to_message_id: string | null;
  created_at: string;
}

interface MentionRow {
  message_id: string;
  target_id: string;
  target_type: ActorType;
}

export class ReplyNotInConversationError extends Error {}

function getMentions(db: Database.Database, messageId: string): MentionRef[] {
  const rows = db.prepare('SELECT * FROM message_mentions WHERE message_id = ?').all(messageId) as MentionRow[];
  return rows.map((r) => ({ targetId: r.target_id, targetType: r.target_type }));
}

function rowToMessage(row: MessageRow, mentions: MentionRef[]): Message {
  return MessageSchema.parse({
    id: row.id,
    conversationId: row.conversation_id,
    authorId: row.author_id,
    authorType: row.author_type,
    body: row.body,
    mentions,
    replyToMessageId: row.reply_to_message_id,
    createdAt: row.created_at,
  });
}

export function createMessage(
  db: Database.Database,
  input: {
    conversationId: string;
    authorId: string;
    authorType: ActorType;
    body: string;
    mentions: MentionRef[];
    replyToMessageId: string | null;
  }
): Message {
  if (input.replyToMessageId) {
    const replyTarget = db.prepare('SELECT conversation_id FROM messages WHERE id = ?').get(input.replyToMessageId) as
      | { conversation_id: string }
      | undefined;
    if (!replyTarget || replyTarget.conversation_id !== input.conversationId) {
      throw new ReplyNotInConversationError('replyToMessageId must reference a message in the same conversation');
    }
  }

  const now = new Date().toISOString();
  const row: MessageRow = {
    id: randomUUID(),
    conversation_id: input.conversationId,
    author_id: input.authorId,
    author_type: input.authorType,
    body: input.body,
    reply_to_message_id: input.replyToMessageId,
    created_at: now,
  };
  const insertMessage = db.prepare(
    `INSERT INTO messages (id, conversation_id, author_id, author_type, body, reply_to_message_id, created_at)
     VALUES (@id, @conversation_id, @author_id, @author_type, @body, @reply_to_message_id, @created_at)`
  );
  const insertMention = db.prepare('INSERT INTO message_mentions (message_id, target_id, target_type) VALUES (?, ?, ?)');
  const createTx = db.transaction(() => {
    insertMessage.run(row);
    for (const m of input.mentions) {
      insertMention.run(row.id, m.targetId, m.targetType);
    }
  });
  createTx();
  return rowToMessage(row, input.mentions);
}

export function listMessagesForConversation(db: Database.Database, conversationId: string, limit = 50): Message[] {
  const rows = db
    .prepare('SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC, rowid ASC LIMIT ?')
    .all(conversationId, limit) as MessageRow[];
  return rows.map((row) => rowToMessage(row, getMentions(db, row.id)));
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/messages/repository.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0006_messages.sql src/messages/repository.ts src/messages/repository.test.ts
git commit -m "feat: add messages table and repository with mentions and replies"
```

---

### Task 4: Message REST routes (persist-then-publish)

**Files:**
- Create: `repos/server/src/messages/routes.ts`
- Test: `repos/server/src/messages/routes.test.ts`
- Modify: `repos/server/src/app.ts`

**Interfaces:**
- Consumes: `createMessage`, `listMessagesForConversation`,
  `ReplyNotInConversationError` from Task 3. `getConversation`,
  `isParticipant` from Task 1. `ConnectionHub`/`hub.publish` from
  `../ws/hub.js` (existing, unchanged).
- Produces: `registerMessageRoutes(app: FastifyInstance, hub: ConnectionHub):
  void` adding `POST /api/conversations/:id/messages` and
  `GET /api/conversations/:id/messages`, both behind `requireAuth` and
  restricted to conversation participants. `POST` persists via `createMessage`
  FIRST, then calls `hub.publish('conversation:<id>', 'message.created',
  {...message})` — this is the persist-before-broadcast guarantee applied to
  real conversation traffic.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/messages/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { createSession } from '../auth/session.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';

describe('message routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupOwnerAndBobDm(app: Awaited<ReturnType<typeof buildApp>>) {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const token = setup.json().token as string;
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const create = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: bob.id, participantType: 'user' },
    });
    return { token, conversationId: create.json().id as string };
  }

  it('posts a message and lists it back', async () => {
    const app = await buildApp({ db });
    const { token, conversationId } = await setupOwnerAndBobDm(app);

    const post = await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
      payload: { body: 'hello there' },
    });
    expect(post.statusCode).toBe(201);
    expect(post.json().body).toBe('hello there');

    const list = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toHaveLength(1);

    await app.close();
  });

  it('rejects posting a message from a non-participant', async () => {
    const app = await buildApp({ db });
    const { conversationId } = await setupOwnerAndBobDm(app);
    const outsider = createUser(db, { email: 'outsider@example.com', displayName: 'Outsider', passwordHash: 'x', role: 'member' });
    const outsiderToken = createSession(db, outsider.id);

    const post = await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${outsiderToken}` },
      payload: { body: 'i should not be able to post here' },
    });
    expect(post.statusCode).toBe(403);

    await app.close();
  });

  it('rejects a reply that references a message outside the conversation with 400', async () => {
    const app = await buildApp({ db });
    const { token, conversationId } = await setupOwnerAndBobDm(app);
    const otherDm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'x', role: 'member' }).id, participantType: 'user' },
    });
    const elsewhere = await app.inject({
      method: 'POST',
      url: `/api/conversations/${otherDm.json().id}/messages`,
      headers: { authorization: `Bearer ${token}` },
      payload: { body: 'lives elsewhere' },
    });

    const reply = await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
      payload: { body: 'wrong reply', replyToMessageId: elsewhere.json().id },
    });
    expect(reply.statusCode).toBe(400);

    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/messages/routes.test.ts`
Expected: FAIL — `./routes.js` doesn't exist, routes return 404.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/messages/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireAuth } from '../auth/middleware.js';
import { getConversation, isParticipant } from '../conversations/repository.js';
import type { ConnectionHub } from '../ws/hub.js';
import { createMessage, listMessagesForConversation, ReplyNotInConversationError } from './repository.js';

const CreateMessageBodySchema = z.object({
  body: z.string().min(1),
  mentions: z
    .array(z.object({ targetId: z.string().min(1), targetType: z.enum(['user', 'agent']) }))
    .default([]),
  replyToMessageId: z.string().min(1).nullable().default(null),
});

const ListMessagesQuerySchema = z.object({
  limit: z.coerce.number().int().positive().max(200).default(50),
});

export function registerMessageRoutes(app: FastifyInstance, hub: ConnectionHub): void {
  app.post('/api/conversations/:id/messages', { preHandler: requireAuth }, async (request, reply) => {
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
    const body = CreateMessageBodySchema.parse(request.body);

    let message;
    try {
      message = createMessage(app.db, {
        conversationId: id,
        authorId: request.user!.id,
        authorType: 'user',
        body: body.body,
        mentions: body.mentions,
        replyToMessageId: body.replyToMessageId,
      });
    } catch (err) {
      if (err instanceof ReplyNotInConversationError) {
        reply.code(400).send({ error: 'invalid_reply' });
        return;
      }
      throw err;
    }

    hub.publish(`conversation:${id}`, 'message.created', { ...message });
    reply.code(201).send(message);
  });

  app.get('/api/conversations/:id/messages', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isParticipant(app.db, id, request.user!.id, 'user')) {
      reply.code(403).send({ error: 'not_a_participant' });
      return;
    }
    const query = ListMessagesQuerySchema.parse(request.query);
    reply.send(listMessagesForConversation(app.db, id, query.limit));
  });
}
```

Update `repos/server/src/app.ts` (adds one import and one registration call
to the file Task 2 already modified):
```ts
import websocketPlugin from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { ZodError } from 'zod';
import { registerAgentRoutes } from './agents/routes.js';
import { registerAuthRoutes } from './auth/routes.js';
import { registerConversationRoutes } from './conversations/routes.js';
import { registerMessageRoutes } from './messages/routes.js';
import { ConnectionHub } from './ws/hub.js';
import { registerWsRoutes } from './ws/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
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
  registerWsRoutes(app, hub);

  return app;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/messages/routes.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/messages/routes.ts src/messages/routes.test.ts src/app.ts
git commit -m "feat: add message REST routes with persist-then-publish"
```

---

### Task 5: Subscribe `/ws` connections to the caller's conversation topics

**Files:**
- Modify: `repos/server/src/ws/routes.ts`
- Test: `repos/server/src/ws/routes.test.ts` (extend the existing file)

**Interfaces:**
- Consumes: `listConversationsForParticipant` from Task 1.
- Produces: no new exported names — `registerWsRoutes`'s existing signature
  is unchanged. Behavior change only: a connecting client is now subscribed
  to `user:<id>` AND `conversation:<id>` for every conversation it is
  currently a participant of, computed once at connect time (joining a new
  conversation after connecting requires reconnecting to pick up its
  events — acceptable for v0.1, no incremental subscribe is built here).

- [ ] **Step 1: Write the failing test**

First add these two imports to `repos/server/src/ws/routes.test.ts`'s
top-of-file imports:
```ts
import { createUser } from '../users/repository.js';
import { createConversation } from '../conversations/repository.js';
```

Then add this test to the existing top-level `describe` block (open the
file, find the closing of the last `it(...)` block, and add this new test
right before the file's final closing `});`):
```ts
  it('subscribes a connecting client to its conversation topics, not just its user topic', async () => {
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const conversation = createConversation(db, {
      kind: 'dm',
      name: null,
      participants: [
        { participantId: userId, participantType: 'user' },
        { participantId: bob.id, participantType: 'user' },
      ],
    });

    const socket = new WebSocket(`ws://${baseUrl}/ws?token=${token}`);
    await waitForOpen(socket);

    const messagePromise = waitForMessage(socket);
    app.hub.publish(`conversation:${conversation.id}`, 'message.created', { body: 'hi' });
    const received = await messagePromise;

    expect(received.topic).toBe(`conversation:${conversation.id}`);
    socket.close();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/ws/routes.test.ts`
Expected: FAIL — the new test times out waiting for a message, because
`/ws` currently only subscribes to `user:<id>`.

- [ ] **Step 3: Write minimal implementation**

Update `repos/server/src/ws/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { verifySessionToken } from '../auth/session.js';
import { listConversationsForParticipant } from '../conversations/repository.js';
import type { ConnectionHub } from './hub.js';

export function registerWsRoutes(app: FastifyInstance, hub: ConnectionHub): void {
  app.get('/ws', { websocket: true }, (socket, request) => {
    const url = new URL(request.url, 'http://localhost');
    const token = url.searchParams.get('token') ?? '';
    const userId = verifySessionToken(app.db, token);
    if (!userId) {
      socket.close(4001, 'unauthorized');
      return;
    }

    const conversationTopics = listConversationsForParticipant(app.db, userId).map(
      (c) => `conversation:${c.id}`
    );
    const topics = [`user:${userId}`, ...conversationTopics];
    hub.subscribe(socket, topics);

    const sinceSeqParam = url.searchParams.get('sinceSeq');
    if (sinceSeqParam !== null) {
      const missed = hub.replaySince(topics, Number(sinceSeqParam));
      for (const event of missed) {
        socket.send(JSON.stringify(event));
      }
    }

    socket.on('close', () => hub.unsubscribe(socket));
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/ws/routes.test.ts`
Expected: PASS (all tests in the file, including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/ws/routes.ts src/ws/routes.test.ts
git commit -m "feat: subscribe /ws connections to the caller's conversation topics"
```

---

### Task 6: Group membership management routes

**Files:**
- Modify: `repos/server/src/conversations/routes.ts`
- Test: `repos/server/src/conversations/routes.test.ts` (extend the existing
  file)

**Interfaces:**
- Consumes: `getConversation`, `addParticipant`, `removeParticipant` from
  Task 1's repository (not yet imported into `routes.ts` — this task adds
  those imports). `participantExists`/`can`/`Role` already in scope in this
  file from Task 2.
- Produces: `POST /api/conversations/:id/members` and
  `DELETE /api/conversations/:id/members/:participantId`, both behind
  `requireAuth`, restricted to `group` conversations, gated by
  `can(role, 'group:manage_members')` (admin/owner only).

- [ ] **Step 1: Write the failing tests**

First add `createSession` to `repos/server/src/conversations/routes.test.ts`'s
top-of-file imports (Task 2's version of this file doesn't need it, this
task's tests do):
```ts
import { createSession } from '../auth/session.js';
```

Then add these `it` blocks inside the existing top-level
`describe('conversation routes', ...)`, before its closing `});`:
```ts
  it('allows the owner to add and remove a group member', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const carol = createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'y', role: 'member' });

    const group = await app.inject({
      method: 'POST',
      url: '/api/conversations/group',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Team', participants: [{ participantId: bob.id, participantType: 'user' }] },
    });
    const groupId = group.json().id as string;

    const add = await app.inject({
      method: 'POST',
      url: `/api/conversations/${groupId}/members`,
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: carol.id, participantType: 'user' },
    });
    expect(add.statusCode).toBe(204);

    const remove = await app.inject({
      method: 'DELETE',
      url: `/api/conversations/${groupId}/members/${carol.id}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(remove.statusCode).toBe(204);

    await app.close();
  });

  it('rejects membership changes from a member-role user', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const carol = createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'y', role: 'member' });
    const bobToken = createSession(db, bob.id);

    const group = await app.inject({
      method: 'POST',
      url: '/api/conversations/group',
      headers: { authorization: `Bearer ${token}` },
      payload: { name: 'Team', participants: [{ participantId: bob.id, participantType: 'user' }] },
    });
    const groupId = group.json().id as string;

    const add = await app.inject({
      method: 'POST',
      url: `/api/conversations/${groupId}/members`,
      headers: { authorization: `Bearer ${bobToken}` },
      payload: { participantId: carol.id, participantType: 'user' },
    });
    expect(add.statusCode).toBe(403);

    await app.close();
  });

  it('rejects adding a member to a dm conversation', async () => {
    const app = await buildApp({ db });
    const { token } = await setupOwner(app);
    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const carol = createUser(db, { email: 'carol@example.com', displayName: 'Carol', passwordHash: 'y', role: 'member' });

    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: bob.id, participantType: 'user' },
    });

    const add = await app.inject({
      method: 'POST',
      url: `/api/conversations/${dm.json().id}/members`,
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: carol.id, participantType: 'user' },
    });
    expect(add.statusCode).toBe(400);

    await app.close();
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/conversations/routes.test.ts`
Expected: FAIL — the three new tests get 404s, since
`/api/conversations/:id/members` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Update `repos/server/src/conversations/routes.ts`'s import line to add the
three new repository functions:
```ts
import { addParticipant, createConversation, getConversation, listConversationsForParticipant, removeParticipant } from './repository.js';
```

Add this schema next to the other body schemas:
```ts
const AddMemberBodySchema = z.object({
  participantId: z.string().min(1),
  participantType: z.enum(['user', 'agent']),
});
```

Add these two route handlers inside `registerConversationRoutes`, after the
existing `GET /api/conversations` handler:
```ts
  app.post('/api/conversations/:id/members', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const conversation = getConversation(app.db, id);
    if (!conversation) {
      reply.code(404).send({ error: 'conversation_not_found' });
      return;
    }
    if (conversation.kind !== 'group') {
      reply.code(400).send({ error: 'not_a_group' });
      return;
    }
    if (!can(request.user!.role as Role, 'group:manage_members')) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const body = AddMemberBodySchema.parse(request.body);
    if (!participantExists(app, body.participantId, body.participantType)) {
      reply.code(404).send({ error: 'participant_not_found' });
      return;
    }
    addParticipant(app.db, id, { participantId: body.participantId, participantType: body.participantType });
    reply.code(204).send();
  });

  app.delete('/api/conversations/:id/members/:participantId', { preHandler: requireAuth }, async (request, reply) => {
    const { id, participantId } = request.params as { id: string; participantId: string };
    const conversation = getConversation(app.db, id);
    if (!conversation) {
      reply.code(404).send({ error: 'conversation_not_found' });
      return;
    }
    if (conversation.kind !== 'group') {
      reply.code(400).send({ error: 'not_a_group' });
      return;
    }
    if (!can(request.user!.role as Role, 'group:manage_members')) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    removeParticipant(app.db, id, participantId);
    reply.code(204).send();
  });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/conversations/routes.test.ts`
Expected: PASS (all tests in the file, including Task 2's).

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/conversations/routes.ts src/conversations/routes.test.ts
git commit -m "feat: add group membership management routes"
```

---

### Task 7: End-to-end proof — DM/group creation, message persistence, WS delivery, reconnect/replay

**Files:**
- Create: `repos/server/test/messaging-e2e.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1-5 (`buildApp`, conversation/message
  routes, `/ws`). No new production code — this is the charter's explicit
  testing minimums (DM creation, group creation, message persistence,
  WebSocket delivery, reconnect/replay) proven together in one realistic
  scenario, the same way `test/boot.test.ts` proved the foundations plan's
  minimums.

- [ ] **Step 1: Write the test**

`repos/server/test/messaging-e2e.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { buildApp } from '../src/app.js';
import { runMigrations } from '../src/db/migrate.js';
import { createSession } from '../src/auth/session.js';
import { createUser } from '../src/users/repository.js';

describe('messaging end-to-end: dm/group creation, persistence, WS delivery, reconnect/replay', () => {
  let db: Database.Database;
  let app: Awaited<ReturnType<typeof buildApp>>;
  let baseUrl: string;

  beforeEach(async () => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
    app = await buildApp({ db });
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

  it('proves the full messaging path: group creation, message persistence, live WS delivery, and reconnect/replay across a disconnect', async () => {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'alice@example.com', displayName: 'Alice', password: 'super-secret-1' },
    });
    const aliceToken = setup.json().token as string;
    const aliceId = setup.json().user.id as string;

    const bob = createUser(db, { email: 'bob@example.com', displayName: 'Bob', passwordHash: 'x', role: 'member' });
    const bobToken = createSession(db, bob.id);

    const group = await app.inject({
      method: 'POST',
      url: '/api/conversations/group',
      headers: { authorization: `Bearer ${aliceToken}` },
      payload: { name: 'Launch planning', participants: [{ participantId: bob.id, participantType: 'user' }] },
    });
    expect(group.statusCode).toBe(201);
    const conversationId = group.json().id as string;

    const bobSocket = new WebSocket(`ws://${baseUrl}/ws?token=${bobToken}`);
    await waitForOpen(bobSocket);

    const firstMessagePromise = waitForMessage(bobSocket);
    const firstPost = await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${aliceToken}` },
      payload: { body: 'kickoff is monday' },
    });
    expect(firstPost.statusCode).toBe(201);
    const firstReceived = await firstMessagePromise;
    expect(firstReceived.type).toBe('message.created');
    expect((firstReceived.payload as { body: string }).body).toBe('kickoff is monday');
    const lastSeenSeq = firstReceived.seq as number;

    bobSocket.close();
    await new Promise((resolve) => bobSocket.once('close', resolve));

    const secondPost = await app.inject({
      method: 'POST',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${aliceToken}` },
      payload: { body: 'moved to tuesday, sent while bob was offline' },
    });
    expect(secondPost.statusCode).toBe(201);

    const list = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${aliceToken}` },
    });
    expect(list.json()).toHaveLength(2);

    const bobReconnect = new WebSocket(`ws://${baseUrl}/ws?token=${bobToken}&sinceSeq=${lastSeenSeq}`);
    const replayed = await waitForMessage(bobReconnect);
    expect(replayed.type).toBe('message.created');
    expect((replayed.payload as { body: string }).body).toBe('moved to tuesday, sent while bob was offline');
    bobReconnect.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails first (no test/messaging-e2e.test.ts existed before this task)**

Run: `cd repos/server && npx vitest run test/messaging-e2e.test.ts`
Expected: at this point in the plan (after Tasks 1-5) this should actually
PASS immediately, since every piece it exercises was already built and
tested in isolation by earlier tasks — this task's job is proving they
integrate correctly together, which is new information even though no new
production code is written. If it fails, that reveals an integration gap
between two "complete" earlier tasks; fix the integration bug in whichever
task's files are implicated, re-run the earlier task's own test file to
confirm no regression, then re-run this test.

- [ ] **Step 3: Run the full suite and the build to verify the whole plan is sound**

```bash
cd repos/server
npm test
npm run build
```

Expected: every test file passes, `npm run build` succeeds with no
TypeScript errors, and `dist/` contains no `.test.js`/`.test.d.ts` files
(the Task 1 tsconfig fix).

- [ ] **Step 4: Commit**

```bash
cd repos/server
git add test/messaging-e2e.test.ts
git commit -m "test: prove dm/group creation, message persistence, WS delivery, and reconnect/replay end-to-end"
```

---

## What this plan deliberately leaves out

- Agent-to-agent messaging, `rootRunId`/`causationId`/`hopCount`, max-hop
  protection — `server-runtime-and-agent-to-agent` (next plan).
- Incremental WS topic subscription (joining a conversation while connected
  without reconnecting) — no task in this plan needs it; v0.1 requires a
  reconnect to pick up a newly-joined conversation's events. Revisit if this
  becomes a real product requirement.
- Mention-target existence validation (a `targetId` that doesn't correspond
  to a real user/agent is currently accepted silently) — not requested by
  the charter for v0.1, and mentions are advisory metadata, not access
  control.
- Session token hashing at rest, production request logging, `event_log`
  retention/pruning — still carried forward to whichever plan first makes
  them load-bearing (see `docs/specs/2026-09-13-opencrew-backend-charter.md`).
