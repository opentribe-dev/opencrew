# Server Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `repos/server` (`@opencrew/server`) as a single lightweight
process: SQLite+WAL persistence with a migration runner, first-admin/login
authentication with session tokens, a permissions skeleton, Agent CRUD, and a
WebSocket hub that persists every event before broadcasting it and supports
sequence-based reconnect/replay.

**Architecture:** One Fastify HTTP server process. `better-sqlite3` opens a single
`opencrew.db` file in WAL mode under a configurable data directory — no external
services. A hand-rolled migration runner applies numbered `.sql` files and tracks
them in a `schema_migrations` table. Every realtime event (starting with a
`user.updated` event in this plan; message/conversation events are added in the
follow-on messaging-core plan) is first inserted into an `event_log` table — the
row's `seq` (SQLite `AUTOINCREMENT` rowid) *is* the sequence ID — and only then
broadcast over WebSocket to subscribed connections, so `event_log` is the durable
source of truth and WebSocket is pure transport. Reconnecting clients pass
`sinceSeq` and get replayed everything they missed for the topics they're
subscribed to.

**Tech Stack:** Node.js 20+, TypeScript 5, Fastify 5, `@fastify/websocket`,
`better-sqlite3`, `@opencrew/protocol` (local `file:` dependency), Zod, Vitest 2.

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- One server process, one exposed port, one persistent data directory, SQLite+WAL —
  no Postgres/Redis/Kafka/NATS/RabbitMQ/MinIO/separate worker container/Kubernetes.
- Messages (and every other realtime event) must be persisted before broadcast; the
  WebSocket connection is transport, not source of truth.
- Reconnect/replay must use a deterministic sequence mechanism (`event_log.seq`).
- Vendor-specific session IDs must never live on the core Agent row/schema.
- Untested work must not be reported as completed — every task below ends with a
  runnable, passing test.

## Prerequisite

This plan depends on `docs/superpowers/plans/2026-09-13-protocol-foundations.md`
being complete: `repos/protocol` must exist, build (`npm run build`), and pass its
tests, since Task 6 below imports `@opencrew/protocol`.

---

## File Structure

```
repos/server/
  package.json
  tsconfig.json
  vitest.config.ts
  src/
    types.d.ts
    config.ts
    config.test.ts
    app.ts
    index.ts
    db/
      connection.ts
      connection.test.ts
      migrate.ts
      migrate.test.ts
      migrations/
        0001_init.sql
        0002_users.sql
        0003_sessions.sql
        0004_agents.sql
    users/
      repository.ts
      repository.test.ts
    auth/
      password.ts
      password.test.ts
      session.ts
      session.test.ts
      middleware.ts
      routes.ts
      routes.test.ts
    permissions/
      model.ts
      model.test.ts
    agents/
      repository.ts
      repository.test.ts
      routes.ts
      routes.test.ts
    ws/
      hub.ts
      hub.test.ts
      routes.ts
      routes.test.ts
  test/
    boot.test.ts
```

---

### Task 1: Bootstrap the `@opencrew/server` package with a health check

**Files:**
- Create: `repos/server/package.json`
- Create: `repos/server/tsconfig.json`
- Create: `repos/server/vitest.config.ts`
- Create: `repos/server/src/types.d.ts`
- Create: `repos/server/src/app.ts`
- Test: `repos/server/src/app.test.ts`

Note: `repos/server` already has `README.md`/`AGENTS.md`/`CLAUDE.md`/`.gitignore`
on disk (an earlier workspace scaffold), but no `.git` yet — it is not actually a
git repository yet, despite looking like one at a glance. Initialize it fresh and
commit the existing scaffold files as the first commit before branching.

**Interfaces:**
- Produces: `buildApp(opts: BuildAppOptions): Promise<FastifyInstance>` where
  `BuildAppOptions = { db: Database.Database }`. This is the single factory every
  later task's tests and `src/index.ts` use to construct the server. `GET
  /api/health` returns `{ ok: true }`.

- [ ] **Step 1: Initialize the git repo, commit the existing scaffold, create a feature branch, then add new scaffold files**

```bash
cd repos/server
git init -b main
git add README.md AGENTS.md CLAUDE.md .gitignore
git commit -m "chore: initialize repository"
git checkout -b dev-a/server-foundations
```

`repos/server/package.json`:
```json
{
  "name": "@opencrew/server",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc -p tsconfig.json",
    "start": "node dist/index.js",
    "test": "vitest run"
  },
  "dependencies": {
    "@opencrew/protocol": "file:../protocol",
    "fastify": "^5.1.0",
    "@fastify/websocket": "^11.0.1",
    "better-sqlite3": "^11.5.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "typescript": "^5.6.3",
    "vitest": "^2.1.4",
    "tsx": "^4.19.1",
    "ws": "^8.18.0",
    "@types/better-sqlite3": "^7.6.11",
    "@types/ws": "^8.5.12",
    "@types/node": "^22.7.5"
  },
  "engines": {
    "node": ">=20"
  }
}
```

`repos/server/tsconfig.json`:
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
  "include": ["src"]
}
```

`repos/server/vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/*.test.ts', 'test/**/*.test.ts'],
    testTimeout: 10000,
  },
});
```

Update `repos/server/.gitignore` (create if it does not already have these lines):
```
node_modules/
dist/
data/
*.db
*.db-wal
*.db-shm
```

`repos/server/src/types.d.ts` (Task 7 adds the `hub` field once `ws/hub.ts` exists —
see that task; declaring it here would fail the build, since the module it imports
from doesn't exist until then):
```ts
import 'fastify';
import type Database from 'better-sqlite3';

declare module 'fastify' {
  interface FastifyInstance {
    db: Database.Database;
  }
  interface FastifyRequest {
    user?: { id: string; role: string };
  }
}
```

`repos/server/src/app.ts` (minimal for this task — later tasks add to it):
```ts
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';

export interface BuildAppOptions {
  db: Database.Database;
}

export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  app.decorate('db', opts.db);
  app.get('/api/health', async () => ({ ok: true }));
  return app;
}
```

- [ ] **Step 2: Write the failing test**

`repos/server/src/app.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from './app.js';

describe('buildApp', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
  });

  afterEach(() => {
    db.close();
  });

  it('responds to GET /api/health', async () => {
    const app = await buildApp({ db });
    const response = await app.inject({ method: 'GET', url: '/api/health' });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true });
    await app.close();
  });
});
```

- [ ] **Step 3: Install dependencies, then run the test to verify it fails first, then passes**

```bash
cd repos/server
npm install
npx vitest run src/app.test.ts
```

Expected on a clean checkout: PASS immediately, since Step 1 already wrote
`app.ts` alongside the test (this is the one bootstrap task where scaffolding and
first implementation are combined — there is no meaningful "red" state for a
one-line health check). Confirm by temporarily renaming the `app.get` line to a
different path, re-running to see FAIL, then restoring it.

- [ ] **Step 4: Run the full test suite and build to confirm the package is sound**

```bash
cd repos/server
npm test
npm run build
```

Expected: PASS, `dist/index.js` is not yet emitted (no `src/index.ts` yet — that's
fine, `tsc` only errors on type problems, not on a missing entry point being
unreferenced elsewhere).

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add package.json tsconfig.json vitest.config.ts .gitignore src/types.d.ts src/app.ts src/app.test.ts
git commit -m "chore: bootstrap @opencrew/server with health check endpoint"
```

---

### Task 2: SQLite+WAL connection and migration runner

**Files:**
- Create: `repos/server/src/db/connection.ts`
- Test: `repos/server/src/db/connection.test.ts`
- Create: `repos/server/src/db/migrate.ts`
- Test: `repos/server/src/db/migrate.test.ts`
- Create: `repos/server/src/db/migrations/0001_init.sql`
- Create: `repos/server/scripts/copy-migrations.mjs`
- Modify: `repos/server/package.json` (build script)

`tsc` never copies non-`.ts` files, so without this, `dist/db/migrations/*.sql`
would not exist after `npm run build` and a real `npm start` would throw
`ENOENT` reading a missing migrations directory — the tests run against `src/`
directly via vitest, so nothing else in this plan would catch that gap.

**Interfaces:**
- Produces: `openDatabase(dataDir: string): Database.Database` — creates the data
  directory if needed, opens `opencrew.db` inside it, sets `journal_mode = WAL` and
  `foreign_keys = ON`. `runMigrations(db: Database.Database): string[]` — applies
  any `.sql` file in `src/db/migrations/` not yet recorded in `schema_migrations`,
  in filename order, each inside its own transaction; returns the filenames it just
  applied (empty array if already up to date).

- [ ] **Step 1: Write the failing tests**

`repos/server/src/db/connection.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from './connection.js';

describe('openDatabase', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  it('creates the data directory and an opencrew.db file in WAL mode', () => {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-db-'));
    const nestedDir = path.join(dataDir, 'nested');
    const db = openDatabase(nestedDir);
    expect(fs.existsSync(path.join(nestedDir, 'opencrew.db'))).toBe(true);
    const mode = db.pragma('journal_mode', { simple: true });
    expect(mode).toBe('wal');
    db.close();
  });
});
```

`repos/server/src/db/migrate.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from './connection.js';
import { runMigrations } from './migrate.js';

describe('runMigrations', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  it('applies pending migrations once and is idempotent on re-run', () => {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-migrate-'));
    const db = openDatabase(dataDir);

    const firstRun = runMigrations(db);
    expect(firstRun).toContain('0001_init.sql');

    const secondRun = runMigrations(db);
    expect(secondRun).toEqual([]);

    const tables = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'event_log'")
      .all();
    expect(tables).toHaveLength(1);

    db.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/db/connection.test.ts src/db/migrate.test.ts`
Expected: FAIL — `./connection.js` and `./migrate.js` do not exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/connection.ts`:
```ts
import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';

export function openDatabase(dataDir: string): Database.Database {
  fs.mkdirSync(dataDir, { recursive: true });
  const db = new Database(path.join(dataDir, 'opencrew.db'));
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  return db;
}
```

`repos/server/src/db/migrations/0001_init.sql`:
```sql
CREATE TABLE event_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX idx_event_log_topic_seq ON event_log (topic, seq);
```

`repos/server/src/db/migrate.ts`:
```ts
import type Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

export function runMigrations(db: Database.Database): string[] {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
  `);

  const appliedRows = db.prepare('SELECT name FROM schema_migrations').all() as { name: string }[];
  const applied = new Set(appliedRows.map((r) => r.name));

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  const newlyApplied: string[] = [];
  for (const file of files) {
    if (applied.has(file)) continue;
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
    const applyOne = db.transaction(() => {
      db.exec(sql);
      db.prepare('INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)').run(
        file,
        new Date().toISOString()
      );
    });
    applyOne();
    newlyApplied.push(file);
  }
  return newlyApplied;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/db/connection.test.ts src/db/migrate.test.ts`
Expected: PASS

- [ ] **Step 4b: Make migrations survive the build**

`repos/server/scripts/copy-migrations.mjs`:
```js
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(__dirname, '..', 'src', 'db', 'migrations');
const dest = path.join(__dirname, '..', 'dist', 'db', 'migrations');

fs.mkdirSync(dest, { recursive: true });
for (const file of fs.readdirSync(src)) {
  fs.copyFileSync(path.join(src, file), path.join(dest, file));
}
```

Update `repos/server/package.json`'s `build` script:
```json
"build": "tsc -p tsconfig.json && node scripts/copy-migrations.mjs",
```

Run: `cd repos/server && npm run build` and confirm `dist/db/migrations/0001_init.sql` exists.
Expected: file present, build exits 0.

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/connection.ts src/db/connection.test.ts src/db/migrate.ts src/db/migrate.test.ts src/db/migrations/0001_init.sql scripts/copy-migrations.mjs package.json
git commit -m "feat: add SQLite+WAL connection and migration runner"
```

---

### Task 3: Users table, password hashing, and user repository

**Files:**
- Create: `repos/server/src/db/migrations/0002_users.sql`
- Create: `repos/server/src/auth/password.ts`
- Test: `repos/server/src/auth/password.test.ts`
- Create: `repos/server/src/users/repository.ts`
- Test: `repos/server/src/users/repository.test.ts`

**Interfaces:**
- Produces: `hashPassword(password: string): string` (returns `"salt:hash"` hex),
  `verifyPassword(password: string, stored: string): boolean`. `UserRow` type,
  `createUser(db, { email, displayName, passwordHash, role }): UserRow`,
  `getUserByEmail(db, email): UserRow | undefined`, `getUserById(db, id): UserRow |
  undefined`, `countUsers(db): number` (used by the first-admin flow in Task 4).
- Consumes: `runMigrations`/`openDatabase` from Task 2 (tests build a fresh
  in-memory-equivalent temp-dir database and run migrations before exercising the
  repository).

- [ ] **Step 1: Write the failing tests**

`repos/server/src/auth/password.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { hashPassword, verifyPassword } from './password.js';

describe('password hashing', () => {
  it('verifies the correct password', () => {
    const stored = hashPassword('correct horse battery staple');
    expect(verifyPassword('correct horse battery staple', stored)).toBe(true);
  });

  it('rejects an incorrect password', () => {
    const stored = hashPassword('correct horse battery staple');
    expect(verifyPassword('wrong password', stored)).toBe(false);
  });

  it('salts each hash differently for the same password', () => {
    const a = hashPassword('same password');
    const b = hashPassword('same password');
    expect(a).not.toEqual(b);
  });
});
```

`repos/server/src/users/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { countUsers, createUser, getUserByEmail, getUserById } from './repository.js';

describe('users repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDb() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-users-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    return db;
  }

  it('creates a user and reads it back by id and email', () => {
    const db = freshDb();
    const created = createUser(db, {
      email: 'owner@example.com',
      displayName: 'Owner',
      passwordHash: 'salt:hash',
      role: 'owner',
    });
    expect(getUserById(db, created.id)?.email).toBe('owner@example.com');
    expect(getUserByEmail(db, 'owner@example.com')?.id).toBe(created.id);
    db.close();
  });

  it('counts zero users on a fresh database and increments after creation', () => {
    const db = freshDb();
    expect(countUsers(db)).toBe(0);
    createUser(db, { email: 'a@example.com', displayName: 'A', passwordHash: 'x', role: 'member' });
    expect(countUsers(db)).toBe(1);
    db.close();
  });

  it('rejects a duplicate email', () => {
    const db = freshDb();
    createUser(db, { email: 'dup@example.com', displayName: 'A', passwordHash: 'x', role: 'member' });
    expect(() =>
      createUser(db, { email: 'dup@example.com', displayName: 'B', passwordHash: 'y', role: 'member' })
    ).toThrow();
    db.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/auth/password.test.ts src/users/repository.test.ts`
Expected: FAIL — `./password.js` and `./repository.js` do not exist; also
`0002_users.sql` doesn't exist yet so the `users` table wouldn't exist even once the
module compiles.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0002_users.sql`:
```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  created_at TEXT NOT NULL
);
```

`repos/server/src/auth/password.ts`:
```ts
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';

const KEY_LENGTH = 64;

export function hashPassword(password: string): string {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, KEY_LENGTH).toString('hex');
  return `${salt}:${hash}`;
}

export function verifyPassword(password: string, stored: string): boolean {
  const [salt, hash] = stored.split(':');
  if (!salt || !hash) return false;
  const candidate = scryptSync(password, salt, KEY_LENGTH);
  const expected = Buffer.from(hash, 'hex');
  if (candidate.length !== expected.length) return false;
  return timingSafeEqual(candidate, expected);
}
```

`repos/server/src/users/repository.ts`:
```ts
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

export type Role = 'owner' | 'admin' | 'member';

export interface UserRow {
  id: string;
  email: string;
  display_name: string;
  password_hash: string;
  role: Role;
  created_at: string;
}

export function createUser(
  db: Database.Database,
  input: { email: string; displayName: string; passwordHash: string; role: Role }
): UserRow {
  const row: UserRow = {
    id: randomUUID(),
    email: input.email,
    display_name: input.displayName,
    password_hash: input.passwordHash,
    role: input.role,
    created_at: new Date().toISOString(),
  };
  db.prepare(
    `INSERT INTO users (id, email, display_name, password_hash, role, created_at)
     VALUES (@id, @email, @display_name, @password_hash, @role, @created_at)`
  ).run(row);
  return row;
}

export function getUserByEmail(db: Database.Database, email: string): UserRow | undefined {
  return db.prepare('SELECT * FROM users WHERE email = ?').get(email) as UserRow | undefined;
}

export function getUserById(db: Database.Database, id: string): UserRow | undefined {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id) as UserRow | undefined;
}

export function countUsers(db: Database.Database): number {
  const row = db.prepare('SELECT COUNT(*) as count FROM users').get() as { count: number };
  return row.count;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/auth/password.test.ts src/users/repository.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0002_users.sql src/auth/password.ts src/auth/password.test.ts src/users/repository.ts src/users/repository.test.ts
git commit -m "feat: add users table, password hashing, and user repository"
```

---

### Task 4: Sessions, requireAuth middleware, and auth routes (first-admin flow)

**Files:**
- Create: `repos/server/src/db/migrations/0003_sessions.sql`
- Create: `repos/server/src/auth/session.ts`
- Test: `repos/server/src/auth/session.test.ts`
- Create: `repos/server/src/auth/middleware.ts`
- Create: `repos/server/src/auth/routes.ts`
- Test: `repos/server/src/auth/routes.test.ts`
- Modify: `repos/server/src/app.ts`

**Interfaces:**
- Produces: `createSession(db, userId): string` (opaque 64-hex-char token, 30-day
  TTL), `verifySessionToken(db, token): string | undefined` (returns `userId` or
  `undefined` if missing/expired). `requireAuth(request, reply): Promise<void>`
  Fastify `preHandler` that 401s or sets `request.user = { id, role }`.
  `registerAuthRoutes(app: FastifyInstance): void` adding `POST /api/auth/setup`
  (first admin only, 409 once any user exists), `POST /api/auth/login`, `GET
  /api/auth/me`.
- Consumes: `UserRow`/`createUser`/`getUserByEmail`/`getUserById`/`countUsers` from
  Task 3, `hashPassword`/`verifyPassword` from Task 3, `app.db` decorator from
  Task 1.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/auth/session.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createSession, verifySessionToken } from './session.js';

describe('sessions', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithUser() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-sessions-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const user = createUser(db, {
      email: 'a@example.com',
      displayName: 'A',
      passwordHash: 'x',
      role: 'owner',
    });
    return { db, user };
  }

  it('creates a session token that resolves back to the user', () => {
    const { db, user } = freshDbWithUser();
    const token = createSession(db, user.id);
    expect(token).toMatch(/^[a-f0-9]{64}$/);
    expect(verifySessionToken(db, token)).toBe(user.id);
    db.close();
  });

  it('returns undefined for an unknown token', () => {
    const { db } = freshDbWithUser();
    expect(verifySessionToken(db, 'nonexistent')).toBeUndefined();
    db.close();
  });
});
```

`repos/server/src/auth/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';

describe('auth routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  it('allows the first /api/auth/setup call and rejects the second with 409', async () => {
    const app = await buildApp({ db });

    const first = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    expect(first.statusCode).toBe(201);
    expect(first.json().token).toBeTypeOf('string');
    expect(first.json().user.role).toBe('owner');

    const second = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'other@example.com', displayName: 'Other', password: 'super-secret-2' },
    });
    expect(second.statusCode).toBe(409);

    await app.close();
  });

  it('logs in with correct credentials and rejects incorrect ones', async () => {
    const app = await buildApp({ db });
    await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });

    const badLogin = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { email: 'owner@example.com', password: 'wrong-password' },
    });
    expect(badLogin.statusCode).toBe(401);

    const goodLogin = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { email: 'owner@example.com', password: 'super-secret-1' },
    });
    expect(goodLogin.statusCode).toBe(200);
    expect(goodLogin.json().token).toBeTypeOf('string');

    await app.close();
  });

  it('requires a valid bearer token for /api/auth/me', async () => {
    const app = await buildApp({ db });
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    const { token } = setup.json();

    const unauthenticated = await app.inject({ method: 'GET', url: '/api/auth/me' });
    expect(unauthenticated.statusCode).toBe(401);

    const authenticated = await app.inject({
      method: 'GET',
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(authenticated.statusCode).toBe(200);
    expect(authenticated.json().email).toBe('owner@example.com');

    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/auth/session.test.ts src/auth/routes.test.ts`
Expected: FAIL — `./session.js` doesn't exist; `app.ts` has no auth routes yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0003_sessions.sql`:
```sql
CREATE TABLE sessions (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX idx_sessions_user_id ON sessions (user_id);
```

`repos/server/src/auth/session.ts`:
```ts
import type Database from 'better-sqlite3';
import { randomBytes } from 'node:crypto';

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export function createSession(db: Database.Database, userId: string): string {
  const token = randomBytes(32).toString('hex');
  const now = Date.now();
  db.prepare('INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)').run(
    token,
    userId,
    new Date(now).toISOString(),
    new Date(now + SESSION_TTL_MS).toISOString()
  );
  return token;
}

export function verifySessionToken(db: Database.Database, token: string): string | undefined {
  const row = db.prepare('SELECT user_id, expires_at FROM sessions WHERE token = ?').get(token) as
    | { user_id: string; expires_at: string }
    | undefined;
  if (!row) return undefined;
  if (new Date(row.expires_at).getTime() < Date.now()) return undefined;
  return row.user_id;
}
```

`repos/server/src/auth/middleware.ts`:
```ts
import type { FastifyReply, FastifyRequest } from 'fastify';
import { getUserById } from '../users/repository.js';
import { verifySessionToken } from './session.js';

export async function requireAuth(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const header = request.headers.authorization;
  const token = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
  if (!token) {
    reply.code(401).send({ error: 'unauthorized' });
    return;
  }
  const userId = verifySessionToken(request.server.db, token);
  if (!userId) {
    reply.code(401).send({ error: 'unauthorized' });
    return;
  }
  const user = getUserById(request.server.db, userId);
  if (!user) {
    reply.code(401).send({ error: 'unauthorized' });
    return;
  }
  request.user = { id: user.id, role: user.role };
}
```

`repos/server/src/auth/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { countUsers, createUser, getUserByEmail, getUserById } from '../users/repository.js';
import { requireAuth } from './middleware.js';
import { hashPassword, verifyPassword } from './password.js';
import { createSession } from './session.js';

const SetupBodySchema = z.object({
  email: z.string().email(),
  displayName: z.string().min(1),
  password: z.string().min(8),
});

const LoginBodySchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

export function registerAuthRoutes(app: FastifyInstance): void {
  app.post('/api/auth/setup', async (request, reply) => {
    if (countUsers(app.db) > 0) {
      reply.code(409).send({ error: 'already_initialized' });
      return;
    }
    const body = SetupBodySchema.parse(request.body);
    const user = createUser(app.db, {
      email: body.email,
      displayName: body.displayName,
      passwordHash: hashPassword(body.password),
      role: 'owner',
    });
    const token = createSession(app.db, user.id);
    reply.code(201).send({ token, user: { id: user.id, email: user.email, role: user.role } });
  });

  app.post('/api/auth/login', async (request, reply) => {
    const body = LoginBodySchema.parse(request.body);
    const user = getUserByEmail(app.db, body.email);
    if (!user || !verifyPassword(body.password, user.password_hash)) {
      reply.code(401).send({ error: 'invalid_credentials' });
      return;
    }
    const token = createSession(app.db, user.id);
    reply.code(200).send({ token, user: { id: user.id, email: user.email, role: user.role } });
  });

  app.get('/api/auth/me', { preHandler: requireAuth }, async (request, reply) => {
    const user = getUserById(app.db, request.user!.id)!;
    reply.send({ id: user.id, email: user.email, role: user.role });
  });
}
```

Update `repos/server/src/app.ts`:
```ts
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { registerAuthRoutes } from './auth/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
}

export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  app.decorate('db', opts.db);
  app.get('/api/health', async () => ({ ok: true }));
  registerAuthRoutes(app);
  return app;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/auth/session.test.ts src/auth/routes.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0003_sessions.sql src/auth/session.ts src/auth/session.test.ts src/auth/middleware.ts src/auth/routes.ts src/auth/routes.test.ts src/app.ts
git commit -m "feat: add sessions, requireAuth middleware, and first-admin auth routes"
```

---

### Task 5: Permissions skeleton

**Files:**
- Create: `repos/server/src/permissions/model.ts`
- Test: `repos/server/src/permissions/model.test.ts`

**Interfaces:**
- Produces: `Action` (union of action names), `can(role: Role, action: Action):
  boolean`. Used by the group-membership work in the follow-on messaging-core plan,
  and available now for any route that needs a coarse role check.
- Consumes: `Role` from `../users/repository.js` (Task 3) — reuses the single
  definition rather than redeclaring the role union.

- [ ] **Step 1: Write the failing test**

`repos/server/src/permissions/model.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { can } from './model.js';

describe('can', () => {
  it('allows any role to create an agent', () => {
    expect(can('member', 'agent:create')).toBe(true);
    expect(can('admin', 'agent:create')).toBe(true);
    expect(can('owner', 'agent:create')).toBe(true);
  });

  it('requires at least admin to manage group members', () => {
    expect(can('member', 'group:manage_members')).toBe(false);
    expect(can('admin', 'group:manage_members')).toBe(true);
    expect(can('owner', 'group:manage_members')).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/permissions/model.test.ts`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/permissions/model.ts`:
```ts
import type { Role } from '../users/repository.js';

export type Action =
  | 'agent:create'
  | 'agent:manage'
  | 'conversation:create_group'
  | 'group:manage_members';

const ROLE_RANK: Record<Role, number> = { member: 0, admin: 1, owner: 2 };

const ACTION_MIN_ROLE: Record<Action, Role> = {
  'agent:create': 'member',
  'agent:manage': 'member',
  'conversation:create_group': 'member',
  'group:manage_members': 'admin',
};

export function can(role: Role, action: Action): boolean {
  return ROLE_RANK[role] >= ROLE_RANK[ACTION_MIN_ROLE[action]];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/permissions/model.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/permissions/model.ts src/permissions/model.test.ts
git commit -m "feat: add permissions role model"
```

---

### Task 6: Agents table, repository, and REST routes

**Files:**
- Create: `repos/server/src/db/migrations/0004_agents.sql`
- Create: `repos/server/src/agents/repository.ts`
- Test: `repos/server/src/agents/repository.test.ts`
- Create: `repos/server/src/agents/routes.ts`
- Test: `repos/server/src/agents/routes.test.ts`
- Modify: `repos/server/src/app.ts`

**Interfaces:**
- Consumes: `@opencrew/protocol`'s `AgentSchema`/`Agent`/`ModelPolicy`/
  `PermissionSet` (from the protocol-foundations plan) to validate the assembled
  row on every read, guaranteeing the stored shape always matches the shared
  contract. `requireAuth` from Task 4.
- Produces: `createAgent(db, input): Agent`, `getAgent(db, id): Agent | undefined`,
  `listAgentsForOwner(db, ownerUserId): Agent[]`. Routes: `POST /api/agents`,
  `GET /api/agents` (both behind `requireAuth`, scoped to the caller's own agents).
  `runtimeProfiles`/`memory` linkage is intentionally NOT a column here — those
  arrive as separate tables (`agent_runtime_bindings`, `memory_facts`) in the
  runtime and memory follow-on plans, referencing `agents.id` by foreign key, per
  the "vendor session IDs never live on Agent" invariant.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/agents/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent, getAgent, listAgentsForOwner } from './repository.js';

describe('agents repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDbWithUser() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-agents-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const user = createUser(db, {
      email: 'owner@example.com',
      displayName: 'Owner',
      passwordHash: 'x',
      role: 'owner',
    });
    return { db, user };
  }

  it('creates an agent that round-trips through the shared protocol schema', () => {
    const { db, user } = freshDbWithUser();
    const agent = createAgent(db, {
      ownerUserId: user.id,
      name: 'Researcher',
      personality: 'Curious and terse.',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    expect(agent.name).toBe('Researcher');
    expect(getAgent(db, agent.id)?.id).toBe(agent.id);
    db.close();
  });

  it('lists only the agents owned by the given user', () => {
    const { db, user } = freshDbWithUser();
    const otherUser = createUser(db, {
      email: 'other@example.com',
      displayName: 'Other',
      passwordHash: 'y',
      role: 'member',
    });
    createAgent(db, {
      ownerUserId: user.id,
      name: 'Mine',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    createAgent(db, {
      ownerUserId: otherUser.id,
      name: 'TheirsNotMine',
      personality: '',
      modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    const mine = listAgentsForOwner(db, user.id);
    expect(mine).toHaveLength(1);
    expect(mine[0].name).toBe('Mine');
    db.close();
  });
});
```

`repos/server/src/agents/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';

describe('agent routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupAndGetToken(app: Awaited<ReturnType<typeof buildApp>>) {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    return setup.json().token as string;
  }

  it('creates and lists agents for the authenticated user', async () => {
    const app = await buildApp({ db });
    const token = await setupAndGetToken(app);

    const create = await app.inject({
      method: 'POST',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
      payload: {
        name: 'Researcher',
        modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
      },
    });
    expect(create.statusCode).toBe(201);
    expect(create.json().name).toBe('Researcher');

    const list = await app.inject({
      method: 'GET',
      url: '/api/agents',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toHaveLength(1);

    await app.close();
  });

  it('rejects agent creation without authentication', async () => {
    const app = await buildApp({ db });
    const response = await app.inject({
      method: 'POST',
      url: '/api/agents',
      payload: { name: 'Nope', modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'x' } },
    });
    expect(response.statusCode).toBe(401);
    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/agents/repository.test.ts src/agents/routes.test.ts`
Expected: FAIL — `./repository.js`/`./routes.js` don't exist; `agents` table
doesn't exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0004_agents.sql`:
```sql
CREATE TABLE agents (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  personality TEXT NOT NULL DEFAULT '',
  model_policy TEXT NOT NULL,
  permissions TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_agents_owner ON agents (owner_user_id);
```

`repos/server/src/agents/repository.ts`:
```ts
import { AgentSchema, type Agent, type ModelPolicy, type PermissionSet } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

interface AgentRow {
  id: string;
  owner_user_id: string;
  name: string;
  personality: string;
  model_policy: string;
  permissions: string;
  created_at: string;
  updated_at: string;
}

function rowToAgent(row: AgentRow): Agent {
  return AgentSchema.parse({
    id: row.id,
    ownerUserId: row.owner_user_id,
    name: row.name,
    personality: row.personality,
    modelPolicy: JSON.parse(row.model_policy),
    permissions: JSON.parse(row.permissions),
    relationships: [],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

export function createAgent(
  db: Database.Database,
  input: {
    ownerUserId: string;
    name: string;
    personality: string;
    modelPolicy: ModelPolicy;
    permissions: PermissionSet;
  }
): Agent {
  const now = new Date().toISOString();
  const row: AgentRow = {
    id: randomUUID(),
    owner_user_id: input.ownerUserId,
    name: input.name,
    personality: input.personality,
    model_policy: JSON.stringify(input.modelPolicy),
    permissions: JSON.stringify(input.permissions),
    created_at: now,
    updated_at: now,
  };
  db.prepare(
    `INSERT INTO agents (id, owner_user_id, name, personality, model_policy, permissions, created_at, updated_at)
     VALUES (@id, @owner_user_id, @name, @personality, @model_policy, @permissions, @created_at, @updated_at)`
  ).run(row);
  return rowToAgent(row);
}

export function getAgent(db: Database.Database, id: string): Agent | undefined {
  const row = db.prepare('SELECT * FROM agents WHERE id = ?').get(id) as AgentRow | undefined;
  return row ? rowToAgent(row) : undefined;
}

export function listAgentsForOwner(db: Database.Database, ownerUserId: string): Agent[] {
  const rows = db.prepare('SELECT * FROM agents WHERE owner_user_id = ?').all(ownerUserId) as AgentRow[];
  return rows.map(rowToAgent);
}
```

`repos/server/src/agents/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireAuth } from '../auth/middleware.js';
import { createAgent, listAgentsForOwner } from './repository.js';

const CreateAgentBodySchema = z.object({
  name: z.string().min(1),
  personality: z.string().default(''),
  modelPolicy: z.object({
    defaultProviderId: z.string().min(1),
    defaultModel: z.string().min(1),
  }),
});

export function registerAgentRoutes(app: FastifyInstance): void {
  app.post('/api/agents', { preHandler: requireAuth }, async (request, reply) => {
    const body = CreateAgentBodySchema.parse(request.body);
    const agent = createAgent(app.db, {
      ownerUserId: request.user!.id,
      name: body.name,
      personality: body.personality,
      modelPolicy: body.modelPolicy,
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    reply.code(201).send(agent);
  });

  app.get('/api/agents', { preHandler: requireAuth }, async (request, reply) => {
    reply.send(listAgentsForOwner(app.db, request.user!.id));
  });
}
```

Update `repos/server/src/app.ts` to register the new routes:
```ts
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { registerAgentRoutes } from './agents/routes.js';
import { registerAuthRoutes } from './auth/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
}

export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  app.decorate('db', opts.db);
  app.get('/api/health', async () => ({ ok: true }));
  registerAuthRoutes(app);
  registerAgentRoutes(app);
  return app;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npm install && npx vitest run src/agents/repository.test.ts src/agents/routes.test.ts`

(`npm install` is needed the first time `@opencrew/protocol` is imported, so npm
links the local `file:../protocol` dependency — see Prerequisite above.)

Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0004_agents.sql src/agents/repository.ts src/agents/repository.test.ts src/agents/routes.ts src/agents/routes.test.ts src/app.ts
git commit -m "feat: add agents table, repository, and REST routes"
```

---

### Task 7: WebSocket hub — persist-before-broadcast and topic-scoped replay

**Files:**
- Create: `repos/server/src/ws/hub.ts`
- Test: `repos/server/src/ws/hub.test.ts`
- Modify: `repos/server/src/types.d.ts`

**Interfaces:**
- Produces: `class ConnectionHub` with `constructor(db: Database.Database)`,
  `publish(topic: string, type: string, payload: unknown): BroadcastEvent` (inserts
  into `event_log` first, then sends to every currently-subscribed socket on that
  topic — this ordering is the persist-before-broadcast guarantee), `subscribe(socket:
  WebSocket, topics: string[]): void`, `unsubscribe(socket: WebSocket): void`,
  `replaySince(topics: string[], sinceSeq: number): BroadcastEvent[]`.
  `interface BroadcastEvent { seq: number; topic: string; type: string; payload:
  unknown; ts: string }` — shape matches `@opencrew/protocol`'s `WsServerEvent`.
- Consumes: the `event_log` table from Task 2's migration.

- [ ] **Step 1: Write the failing test**

`repos/server/src/ws/hub.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { WebSocket } from 'ws';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { ConnectionHub } from './hub.js';

function fakeSocket() {
  return {
    readyState: 1,
    OPEN: 1,
    send: vi.fn(),
  } as unknown as WebSocket;
}

describe('ConnectionHub', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshHub() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-hub-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    return { db, hub: new ConnectionHub(db) };
  }

  it('persists an event to event_log even with no subscribers', () => {
    const { db, hub } = freshHub();
    const event = hub.publish('user:user_1', 'user.updated', { id: 'user_1' });
    const row = db.prepare('SELECT * FROM event_log WHERE seq = ?').get(event.seq) as
      | { topic: string }
      | undefined;
    expect(row?.topic).toBe('user:user_1');
    db.close();
  });

  it('broadcasts only to sockets subscribed to the matching topic', () => {
    const { hub } = freshHub();
    const subscribed = fakeSocket();
    const notSubscribed = fakeSocket();
    hub.subscribe(subscribed, ['user:user_1']);
    hub.subscribe(notSubscribed, ['user:user_2']);

    hub.publish('user:user_1', 'user.updated', { id: 'user_1' });

    expect(subscribed.send).toHaveBeenCalledTimes(1);
    expect(notSubscribed.send).not.toHaveBeenCalled();
  });

  it('replays only events after sinceSeq for the requested topics', () => {
    const { hub } = freshHub();
    const first = hub.publish('user:user_1', 'user.updated', { n: 1 });
    hub.publish('user:user_1', 'user.updated', { n: 2 });
    hub.publish('user:user_2', 'user.updated', { n: 3 });

    const replayed = hub.replaySince(['user:user_1'], first.seq);
    expect(replayed).toHaveLength(1);
    expect((replayed[0].payload as { n: number }).n).toBe(2);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/ws/hub.test.ts`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/ws/hub.ts`:
```ts
import type Database from 'better-sqlite3';
import type { WebSocket } from 'ws';

interface EventRow {
  seq: number;
  topic: string;
  type: string;
  payload: string;
  created_at: string;
}

export interface BroadcastEvent {
  seq: number;
  topic: string;
  type: string;
  payload: unknown;
  ts: string;
}

export class ConnectionHub {
  private sockets = new Map<WebSocket, Set<string>>();

  constructor(private db: Database.Database) {}

  publish(topic: string, type: string, payload: unknown): BroadcastEvent {
    const createdAt = new Date().toISOString();
    const info = this.db
      .prepare('INSERT INTO event_log (topic, type, payload, created_at) VALUES (?, ?, ?, ?)')
      .run(topic, type, JSON.stringify(payload), createdAt);
    const event: BroadcastEvent = {
      seq: Number(info.lastInsertRowid),
      topic,
      type,
      payload,
      ts: createdAt,
    };
    this.broadcastToTopic(event);
    return event;
  }

  subscribe(socket: WebSocket, topics: string[]): void {
    this.sockets.set(socket, new Set(topics));
  }

  unsubscribe(socket: WebSocket): void {
    this.sockets.delete(socket);
  }

  replaySince(topics: string[], sinceSeq: number): BroadcastEvent[] {
    if (topics.length === 0) return [];
    const placeholders = topics.map(() => '?').join(',');
    const rows = this.db
      .prepare(`SELECT * FROM event_log WHERE topic IN (${placeholders}) AND seq > ? ORDER BY seq ASC`)
      .all(...topics, sinceSeq) as EventRow[];
    return rows.map((r) => ({
      seq: r.seq,
      topic: r.topic,
      type: r.type,
      payload: JSON.parse(r.payload),
      ts: r.created_at,
    }));
  }

  private broadcastToTopic(event: BroadcastEvent): void {
    for (const [socket, topics] of this.sockets) {
      if (topics.has(event.topic) && socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify(event));
      }
    }
  }
}
```

Update `repos/server/src/types.d.ts` to declare `app.hub` now that `ConnectionHub`
exists:
```ts
import 'fastify';
import type Database from 'better-sqlite3';
import type { ConnectionHub } from './ws/hub.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: Database.Database;
    hub: ConnectionHub;
  }
  interface FastifyRequest {
    user?: { id: string; role: string };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/ws/hub.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/ws/hub.ts src/ws/hub.test.ts src/types.d.ts
git commit -m "feat: add ConnectionHub with persist-before-broadcast and topic replay"
```

---

### Task 8: WebSocket route — live delivery and reconnect/replay end-to-end

**Files:**
- Create: `repos/server/src/ws/routes.ts`
- Test: `repos/server/src/ws/routes.test.ts`
- Modify: `repos/server/src/app.ts`

(`repos/server/src/types.d.ts` already declares `app.hub` as of Task 7 — no change
needed here; verify it's present.)

**Interfaces:**
- Produces: `registerWsRoutes(app: FastifyInstance, hub: ConnectionHub): void`
  adding `GET /ws?token=<sessionToken>&sinceSeq=<n>`. On connect: verifies the
  session token (401-equivalent close code `4001` if invalid), subscribes the
  socket to `user:<userId>`, and if `sinceSeq` is present, immediately replays
  missed events for that topic before any new live events. `buildApp` now also
  registers `@fastify/websocket` and constructs/decorates the shared `ConnectionHub`
  as `app.hub`.
- Consumes: `ConnectionHub` from Task 7, `verifySessionToken` from Task 4.

- [ ] **Step 1: Write the failing test**

`repos/server/src/ws/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { buildApp } from '../app.js';
import { runMigrations } from '../db/migrate.js';

describe('WebSocket delivery and reconnect/replay', () => {
  let db: Database.Database;
  let app: Awaited<ReturnType<typeof buildApp>>;
  let baseUrl: string;
  let token: string;
  let userId: string;

  beforeEach(async () => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
    app = await buildApp({ db });
    await app.listen({ port: 0, host: '127.0.0.1' });
    const address = app.server.address();
    if (typeof address === 'string' || address === null) throw new Error('expected AddressInfo');
    baseUrl = `127.0.0.1:${address.port}`;

    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    token = setup.json().token;
    userId = setup.json().user.id;
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

  it('delivers a live event published after the socket connects', async () => {
    const socket = new WebSocket(`ws://${baseUrl}/ws?token=${token}`);
    await waitForOpen(socket);

    const messagePromise = waitForMessage(socket);
    app.hub.publish(`user:${userId}`, 'user.updated', { hello: 'world' });
    const received = await messagePromise;

    expect(received.type).toBe('user.updated');
    expect(received.payload).toEqual({ hello: 'world' });
    socket.close();
  });

  it('replays events published while disconnected when reconnecting with sinceSeq', async () => {
    const firstSocket = new WebSocket(`ws://${baseUrl}/ws?token=${token}`);
    await waitForOpen(firstSocket);
    firstSocket.close();
    await new Promise((resolve) => firstSocket.once('close', resolve));

    const missedWhileDisconnected = app.hub.publish(`user:${userId}`, 'user.updated', { n: 1 });

    const secondSocket = new WebSocket(`ws://${baseUrl}/ws?token=${token}&sinceSeq=0`);
    const replayed = await waitForMessage(secondSocket);

    expect(replayed.seq).toBe(missedWhileDisconnected.seq);
    expect(replayed.payload).toEqual({ n: 1 });
    secondSocket.close();
  });

  it('closes the connection with 4001 for an invalid token', async () => {
    const socket = new WebSocket(`ws://${baseUrl}/ws?token=not-a-real-token`);
    const closeCode = await new Promise<number>((resolve) => socket.once('close', resolve));
    expect(closeCode).toBe(4001);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/ws/routes.test.ts`
Expected: FAIL — `./routes.js` doesn't exist and `/ws` isn't registered.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/ws/routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import { verifySessionToken } from '../auth/session.js';
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

    const topics = [`user:${userId}`];
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

Update `repos/server/src/app.ts` to register the websocket plugin, construct the
hub, and wire the route:
```ts
import websocketPlugin from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type Database from 'better-sqlite3';
import { registerAgentRoutes } from './agents/routes.js';
import { registerAuthRoutes } from './auth/routes.js';
import { ConnectionHub } from './ws/hub.js';
import { registerWsRoutes } from './ws/routes.js';

export interface BuildAppOptions {
  db: Database.Database;
}

export async function buildApp(opts: BuildAppOptions): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  app.decorate('db', opts.db);
  const hub = new ConnectionHub(opts.db);
  app.decorate('hub', hub);
  await app.register(websocketPlugin);

  app.get('/api/health', async () => ({ ok: true }));
  registerAuthRoutes(app);
  registerAgentRoutes(app);
  registerWsRoutes(app, hub);

  return app;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/ws/routes.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/ws/routes.ts src/ws/routes.test.ts src/app.ts
git commit -m "feat: add /ws route with live delivery and sinceSeq reconnect/replay"
```

---

### Task 9: Entry point, config loading, and full boot integration test

**Files:**
- Create: `repos/server/src/config.ts`
- Test: `repos/server/src/config.test.ts`
- Create: `repos/server/src/index.ts`
- Create: `repos/server/test/boot.test.ts`

**Interfaces:**
- Produces: `interface AppConfig { port: number; dataDir: string }`,
  `loadConfig(env?: NodeJS.ProcessEnv): AppConfig` — reads `OPENCREW_PORT` (default
  `4000`) and `OPENCREW_DATA_DIR` (default `<cwd>/data`). `src/index.ts`'s `main()`
  wires `loadConfig` → `openDatabase` → `runMigrations` → `buildApp` → `app.listen`,
  the exact sequence the self-host deployment runs in production.
- Consumes: `openDatabase`/`runMigrations` (Task 2), `buildApp` (Tasks 1-8).

- [ ] **Step 1: Write the failing tests**

`repos/server/src/config.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { loadConfig } from './config.js';

describe('loadConfig', () => {
  it('defaults to port 4000 and a local data directory', () => {
    const config = loadConfig({});
    expect(config.port).toBe(4000);
    expect(config.dataDir).toMatch(/data$/);
  });

  it('reads OPENCREW_PORT and OPENCREW_DATA_DIR when set', () => {
    const config = loadConfig({ OPENCREW_PORT: '5050', OPENCREW_DATA_DIR: '/tmp/opencrew-data' });
    expect(config.port).toBe(5050);
    expect(config.dataDir).toBe('/tmp/opencrew-data');
  });
});
```

`repos/server/test/boot.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { openDatabase } from '../src/db/connection.js';
import { runMigrations } from '../src/db/migrate.js';

describe('full boot sequence', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  it('boots against a real on-disk SQLite database and serves the first-admin flow', async () => {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-boot-'));
    const db = openDatabase(dataDir);
    const applied = runMigrations(db);
    expect(applied.length).toBeGreaterThan(0);

    const app = await buildApp({ db });

    const health = await app.inject({ method: 'GET', url: '/api/health' });
    expect(health.statusCode).toBe(200);

    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    expect(setup.statusCode).toBe(201);

    await app.close();
    db.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/config.test.ts test/boot.test.ts`
Expected: `config.test.ts` FAILs (`./config.js` doesn't exist); `boot.test.ts` may
already pass since it only exercises existing pieces — if so, that's fine, it is
still the task's required regression test going forward.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/config.ts`:
```ts
import path from 'node:path';

export interface AppConfig {
  port: number;
  dataDir: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const dataDir = env.OPENCREW_DATA_DIR ?? path.resolve(process.cwd(), 'data');
  const port = env.OPENCREW_PORT ? Number(env.OPENCREW_PORT) : 4000;
  return { port, dataDir };
}
```

`repos/server/src/index.ts`:
```ts
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { openDatabase } from './db/connection.js';
import { runMigrations } from './db/migrate.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const db = openDatabase(config.dataDir);
  runMigrations(db);
  const app = await buildApp({ db });
  await app.listen({ port: config.port, host: '0.0.0.0' });
  console.log(`OpenCrew server listening on port ${config.port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 4: Run tests to verify they pass, then run the full suite and build**

```bash
cd repos/server
npx vitest run src/config.test.ts test/boot.test.ts
npm test
npm run build
```

Expected: PASS across the whole suite; `npm run build` emits `dist/index.js` with
no TypeScript errors.

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/config.ts src/config.test.ts src/index.ts test/boot.test.ts
git commit -m "feat: add config loading and entry point; full boot integration test"
```

---

## What this plan deliberately leaves out (see charter's plan sequencing)

- Conversations/DMs/groups/mentions/replies and their WS topics — `server-messaging-core`.
- RuntimeSession/RuntimeBinding persistence, Native Agent runtime loop, agent-to-agent
  hop-count enforcement, approvals — `server-runtime-and-agent-to-agent`.
- Provider abstraction and Anthropic/OpenAI/OpenRouter/DeepSeek/Claude Subscription/
  Ollama clients — `server-providers`.
- MemoryFact CRUD/dedup, rolling summaries, background jobs — `server-memory-and-jobs`.
- `repos/sdk` client — `sdk-client`.
- `repos/cloud` — `cloud-foundations`.

Do not implement these here; each has its own plan so a reviewer can approve this
foundational slice independently of the larger runtime/provider work.
