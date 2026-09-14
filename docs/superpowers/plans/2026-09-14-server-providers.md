# Server Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a provider abstraction (Anthropic, OpenAI, OpenRouter, DeepSeek,
generic OpenAI-compatible, plus agentd-backed Claude Subscription/Ollama
stubs) to `@opencrew/server`, and a real `RespondFn` implementation that
slots into `runAgentTurn`'s existing seam without changing its shape.

**Architecture:** A `ProviderClient` interface (`chat`, `listModels`) that
every remote provider implements against an injectable `fetch` function
(defaulting to the real global `fetch`, swapped for a fake in tests — the
same pattern already established for `RespondFn` in the runtime plan). Four
of the five remote provider kinds (openai, openrouter, deepseek,
openai-compatible) are genuinely OpenAI-compatible chat/completions APIs, so
they share ONE `OpenAICompatibleClient` parametrized by base URL; only
Anthropic needs its own client (different request/response shape). Provider
credentials are stored server-wide (one self-hosted instance, one set of
keys — no per-user/per-agent credential system, matching the charter's
lightweight self-host goal). `createProviderRespond(db, fetchImpl?)` builds
the actual `RespondFn`: it reads the invoked agent's `modelPolicy`, calls the
resolved provider, and on a typed provider failure retries the agent's
configured fallback provider once before degrading to a safe, persisted
error message — never a crash, never a silently-dropped broadcast.

**Tech Stack:** Same as `@opencrew/server` — Fastify 5, better-sqlite3,
`@opencrew/protocol`, Zod, Vitest 2, Node 20's native `fetch`/`Response`. No
new dependencies.

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- No mandatory external services — a server with zero providers configured
  must still boot and run its full existing test suite unchanged.
- No network calls to real LLM APIs from this repo's own test suite — every
  provider client takes an injectable `fetch`, defaulting to the real one.
- Claude Subscription and Ollama are agentd-backed; agentd does not exist in
  this workspace yet (Developer B's responsibility). This plan must not
  implement an agentd client or any network call to a nonexistent service —
  those two provider kinds get a stub client that throws a clear, typed
  "not yet available" error, never a faked success.
- A provider failure must never crash the whole agent-to-agent chain or
  leave a half-broadcast message — `runAgentTurn`'s existing persist-then-
  publish flow is untouched; failures are caught and translated to a safe
  `AgentTurnResult` before they ever reach the engine.
- `RespondFn`'s signature (`(input: { agentId, conversationId,
  recentMessages }) => Promise<AgentTurnResult>`) and `runAgentTurn`'s
  persistence/orchestration code are not modified by this plan — only a new
  concrete implementation is added and wired in as an option.
- Untested work must not be reported as completed.

## Prerequisite

`repos/server` is on `main` (protocol-foundations, server-foundations,
server-messaging-core, and server-runtime-and-agent-to-agent plans all
merged) and `repos/protocol` is on `main` with `provider.ts`/`agentd.ts`
schemas already published. Next migration number is `0011` (`0001`-`0010`
already exist). This plan works on `repos/server`'s `main` via a new feature
branch.

---

## File Structure

```
repos/server/
  src/
    app.ts                             # modified: register provider routes
    index.ts                           # modified: wire createProviderRespond in production
    permissions/model.ts                # modified: add 'provider:manage' action
    db/migrations/
      0011_provider_configs.sql
    providers/
      errors.ts
      client.ts
      anthropic.ts
      anthropic.test.ts
      openai-compatible.ts
      openai-compatible.test.ts
      agentd-stub.ts
      agentd-stub.test.ts
      registry.ts
      registry.test.ts
      repository.ts
      repository.test.ts
      respond.ts
      respond.test.ts
      routes.ts
      routes.test.ts
  test/
    provider-e2e.test.ts
```

---

### Task 1: Provider config persistence

**Files:**
- Create: `repos/server/src/db/migrations/0011_provider_configs.sql`
- Create: `repos/server/src/providers/repository.ts`
- Test: `repos/server/src/providers/repository.test.ts`

**Interfaces:**
- Consumes: `ProviderKind` from `@opencrew/protocol` (already published, no
  change needed there).
- Produces: `interface ProviderConfigRecord { id: string; kind: ProviderKind;
  apiKey: string | null; baseUrl: string | null; createdAt: string;
  updatedAt: string }`. `createProviderConfig(db, { id: string; kind:
  ProviderKind; apiKey?: string | null; baseUrl?: string | null }):
  ProviderConfigRecord` — note `id` is CALLER-SUPPLIED (not a generated
  UUID), because it's the same free-form string an `Agent`'s
  `modelPolicy.defaultProviderId`/`fallbackProviderId` already references
  (established in the protocol-foundations plan). `getProviderConfig(db,
  id): ProviderConfigRecord | undefined`. `listProviderConfigs(db):
  ProviderConfigRecord[]`. Every later task builds on these exact names.

There is deliberately no `@opencrew/protocol` schema validation on this
table (unlike `agents`/`conversations`/`messages`): provider credentials and
base-URL overrides are server-internal configuration, not part of the
vendor-neutral wire protocol — the same precedent already set by
`users`/`sessions` in this codebase, which also have no protocol schema.

- [ ] **Step 1: Write the failing test**

`repos/server/src/providers/repository.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createProviderConfig, getProviderConfig, listProviderConfigs } from './repository.js';

describe('provider config repository', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshDb() {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-providers-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    return db;
  }

  it('creates a provider config with a caller-supplied id and reads it back', () => {
    const db = freshDb();
    const config = createProviderConfig(db, { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-test' });
    expect(config.id).toBe('anthropic-default');
    expect(config.apiKey).toBe('sk-test');
    expect(getProviderConfig(db, 'anthropic-default')?.kind).toBe('anthropic');
    db.close();
  });

  it('allows an agentd-backed provider with no stored api key', () => {
    const db = freshDb();
    const config = createProviderConfig(db, { id: 'my-claude-subscription', kind: 'claude-subscription' });
    expect(config.apiKey).toBeNull();
    db.close();
  });

  it('lists all configured providers', () => {
    const db = freshDb();
    createProviderConfig(db, { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-test' });
    createProviderConfig(db, { id: 'openai-default', kind: 'openai', apiKey: 'sk-openai' });
    expect(listProviderConfigs(db)).toHaveLength(2);
    db.close();
  });

  it('rejects a duplicate id', () => {
    const db = freshDb();
    createProviderConfig(db, { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-test' });
    expect(() => createProviderConfig(db, { id: 'anthropic-default', kind: 'openai', apiKey: 'sk-other' })).toThrow();
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/providers/repository.test.ts`
Expected: FAIL — module and table don't exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/db/migrations/0011_provider_configs.sql`:
```sql
CREATE TABLE provider_configs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('anthropic', 'openai', 'openrouter', 'deepseek', 'openai-compatible', 'claude-subscription', 'ollama')),
  api_key TEXT,
  base_url TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

`repos/server/src/providers/repository.ts`:
```ts
import type { ProviderKind } from '@opencrew/protocol';
import type Database from 'better-sqlite3';

export interface ProviderConfigRecord {
  id: string;
  kind: ProviderKind;
  apiKey: string | null;
  baseUrl: string | null;
  createdAt: string;
  updatedAt: string;
}

interface ProviderConfigRow {
  id: string;
  kind: ProviderKind;
  api_key: string | null;
  base_url: string | null;
  created_at: string;
  updated_at: string;
}

function rowToProviderConfig(row: ProviderConfigRow): ProviderConfigRecord {
  return {
    id: row.id,
    kind: row.kind,
    apiKey: row.api_key,
    baseUrl: row.base_url,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function createProviderConfig(
  db: Database.Database,
  input: { id: string; kind: ProviderKind; apiKey?: string | null; baseUrl?: string | null }
): ProviderConfigRecord {
  const now = new Date().toISOString();
  const row: ProviderConfigRow = {
    id: input.id,
    kind: input.kind,
    api_key: input.apiKey ?? null,
    base_url: input.baseUrl ?? null,
    created_at: now,
    updated_at: now,
  };
  db.prepare(
    `INSERT INTO provider_configs (id, kind, api_key, base_url, created_at, updated_at)
     VALUES (@id, @kind, @api_key, @base_url, @created_at, @updated_at)`
  ).run(row);
  return rowToProviderConfig(row);
}

export function getProviderConfig(db: Database.Database, id: string): ProviderConfigRecord | undefined {
  const row = db.prepare('SELECT * FROM provider_configs WHERE id = ?').get(id) as ProviderConfigRow | undefined;
  return row ? rowToProviderConfig(row) : undefined;
}

export function listProviderConfigs(db: Database.Database): ProviderConfigRecord[] {
  const rows = db.prepare('SELECT * FROM provider_configs ORDER BY created_at ASC').all() as ProviderConfigRow[];
  return rows.map(rowToProviderConfig);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/providers/repository.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/db/migrations/0011_provider_configs.sql src/providers/repository.ts src/providers/repository.test.ts
git commit -m "feat: add provider config persistence"
```

---

### Task 2: Provider client contract, errors, and the Anthropic client

**Files:**
- Create: `repos/server/src/providers/errors.ts`
- Create: `repos/server/src/providers/client.ts`
- Create: `repos/server/src/providers/anthropic.ts`
- Test: `repos/server/src/providers/anthropic.test.ts`

**Interfaces:**
- Consumes: `ChatRequest`, `ChatResponse`, `ModelInfo` from
  `@opencrew/protocol`.
- Produces: `class ProviderError extends Error`, `class
  ProviderUnavailableError extends ProviderError`, `class ProviderAuthError
  extends ProviderError`, `class ProviderRateLimitError extends
  ProviderError` — the base class lets callers distinguish "a known provider
  failure mode" from "an unexpected bug" via `instanceof ProviderError`.
  `interface ProviderClient { readonly kind: ProviderKind; chat(request:
  ChatRequest): Promise<ChatResponse>; listModels(): Promise<ModelInfo[]> }`.
  `class AnthropicClient implements ProviderClient` with `constructor(apiKey:
  string, fetchImpl?: typeof fetch, baseUrl?: string)`. Every later provider
  client and the registry (Task 3) implement/consume this same
  `ProviderClient` interface and error hierarchy.

- [ ] **Step 1: Write the failing test**

`repos/server/src/providers/anthropic.test.ts`:
```ts
import { describe, expect, it, vi } from 'vitest';
import { AnthropicClient } from './anthropic.js';
import { ProviderAuthError, ProviderRateLimitError, ProviderUnavailableError } from './errors.js';

describe('AnthropicClient', () => {
  it('sends the request and maps a successful response', async () => {
    const fakeFetch = vi.fn(async () =>
      new Response(
        JSON.stringify({
          content: [{ type: 'text', text: 'hello there' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 10, output_tokens: 5 },
        }),
        { status: 200 }
      )
    );
    const client = new AnthropicClient('sk-test', fakeFetch as unknown as typeof fetch);

    const response = await client.chat({
      providerId: 'anthropic-default',
      model: 'claude-sonnet-5',
      messages: [{ role: 'user', content: 'hi' }],
    });

    expect(response.content).toBe('hello there');
    expect(response.stopReason).toBe('end_turn');
    expect(response.usage).toEqual({ inputTokens: 10, outputTokens: 5 });
    expect(fakeFetch).toHaveBeenCalledWith(
      'https://api.anthropic.com/v1/messages',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({ 'x-api-key': 'sk-test' }),
      })
    );
  });

  it('throws ProviderAuthError on a 401 response', async () => {
    const fakeFetch = vi.fn(async () => new Response('{}', { status: 401 }));
    const client = new AnthropicClient('bad-key', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'anthropic-default', model: 'claude-sonnet-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderAuthError);
  });

  it('throws ProviderRateLimitError on a 429 response', async () => {
    const fakeFetch = vi.fn(async () => new Response('{}', { status: 429 }));
    const client = new AnthropicClient('sk-test', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'anthropic-default', model: 'claude-sonnet-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderRateLimitError);
  });

  it('throws ProviderUnavailableError when the network request itself fails', async () => {
    const fakeFetch = vi.fn(async () => {
      throw new Error('ECONNREFUSED');
    });
    const client = new AnthropicClient('sk-test', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'anthropic-default', model: 'claude-sonnet-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderUnavailableError);
  });

  it('lists a non-empty set of models with positive context windows', async () => {
    const client = new AnthropicClient('sk-test');
    const models = await client.listModels();
    expect(models.length).toBeGreaterThan(0);
    for (const model of models) {
      expect(model.contextWindow).toBeGreaterThan(0);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/providers/anthropic.test.ts`
Expected: FAIL — modules do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/providers/errors.ts`:
```ts
export class ProviderError extends Error {}
export class ProviderUnavailableError extends ProviderError {}
export class ProviderAuthError extends ProviderError {}
export class ProviderRateLimitError extends ProviderError {}
```

`repos/server/src/providers/client.ts`:
```ts
import type { ChatRequest, ChatResponse, ModelInfo, ProviderKind } from '@opencrew/protocol';

export interface ProviderClient {
  readonly kind: ProviderKind;
  chat(request: ChatRequest): Promise<ChatResponse>;
  listModels(): Promise<ModelInfo[]>;
}
```

`repos/server/src/providers/anthropic.ts`:
```ts
import type { ChatRequest, ChatResponse, ModelInfo } from '@opencrew/protocol';
import type { ProviderClient } from './client.js';
import { ProviderAuthError, ProviderRateLimitError, ProviderUnavailableError } from './errors.js';

interface AnthropicChatResponseBody {
  content: { type: string; text?: string }[];
  stop_reason: string;
  usage: { input_tokens: number; output_tokens: number };
}

export class AnthropicClient implements ProviderClient {
  readonly kind = 'anthropic' as const;

  constructor(
    private apiKey: string,
    private fetchImpl: typeof fetch = fetch,
    private baseUrl = 'https://api.anthropic.com'
  ) {}

  async chat(request: ChatRequest): Promise<ChatResponse> {
    const system = request.messages
      .filter((m) => m.role === 'system')
      .map((m) => m.content)
      .join('\n');
    const messages = request.messages
      .filter((m) => m.role !== 'system')
      .map((m) => ({ role: m.role, content: m.content }));

    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}/v1/messages`, {
        method: 'POST',
        headers: {
          'x-api-key': this.apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model: request.model,
          max_tokens: request.maxTokens ?? 1024,
          system: system || undefined,
          messages,
        }),
      });
    } catch (err) {
      throw new ProviderUnavailableError(`anthropic request failed: ${(err as Error).message}`);
    }

    if (response.status === 401 || response.status === 403) {
      throw new ProviderAuthError(`anthropic auth failed with status ${response.status}`);
    }
    if (response.status === 429) {
      throw new ProviderRateLimitError('anthropic rate limited');
    }
    if (!response.ok) {
      throw new ProviderUnavailableError(`anthropic returned status ${response.status}`);
    }

    const data = (await response.json()) as AnthropicChatResponseBody;
    const text = data.content
      .filter((block) => block.type === 'text')
      .map((block) => block.text ?? '')
      .join('');

    return {
      providerId: request.providerId,
      model: request.model,
      content: text,
      stopReason: data.stop_reason === 'end_turn' ? 'end_turn' : data.stop_reason === 'max_tokens' ? 'max_tokens' : 'error',
      usage: { inputTokens: data.usage.input_tokens, outputTokens: data.usage.output_tokens },
    };
  }

  async listModels(): Promise<ModelInfo[]> {
    return [
      { id: 'claude-sonnet-5', providerId: 'anthropic', displayName: 'Claude Sonnet 5', contextWindow: 200000 },
      { id: 'claude-opus-5', providerId: 'anthropic', displayName: 'Claude Opus 5', contextWindow: 200000 },
      { id: 'claude-haiku-4-5', providerId: 'anthropic', displayName: 'Claude Haiku 4.5', contextWindow: 200000 },
    ];
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/providers/anthropic.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/providers/errors.ts src/providers/client.ts src/providers/anthropic.ts src/providers/anthropic.test.ts
git commit -m "feat: add provider client contract, typed errors, and Anthropic client"
```

---

### Task 3: OpenAI-compatible client, agentd-backed stub, and the provider registry

**Files:**
- Create: `repos/server/src/providers/openai-compatible.ts`
- Test: `repos/server/src/providers/openai-compatible.test.ts`
- Create: `repos/server/src/providers/agentd-stub.ts`
- Test: `repos/server/src/providers/agentd-stub.test.ts`
- Create: `repos/server/src/providers/registry.ts`
- Test: `repos/server/src/providers/registry.test.ts`

**Interfaces:**
- Consumes: `ProviderClient`, `ProviderError` family from Task 2.
  `ProviderConfigRecord` from Task 1.
- Produces: `class OpenAICompatibleClient implements ProviderClient` with
  `constructor(kind: ProviderKind, baseUrl: string, apiKey: string,
  fetchImpl?: typeof fetch)` — used for `openai`, `openrouter`, `deepseek`,
  and `openai-compatible`, since all four speak the same
  `/chat/completions` + `/models` shape. `class AgentdBackedProviderClient
  implements ProviderClient` with `constructor(kind: ProviderKind)` — used
  for `claude-subscription`/`ollama`; both methods always reject with
  `ProviderUnavailableError`. `resolveProviderClient(config:
  ProviderConfigRecord, fetchImpl?: typeof fetch): ProviderClient` — the
  factory Task 4 and the REST routes (Task 5) both use.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/providers/openai-compatible.test.ts`:
```ts
import { describe, expect, it, vi } from 'vitest';
import { OpenAICompatibleClient } from './openai-compatible.js';
import { ProviderAuthError, ProviderRateLimitError, ProviderUnavailableError } from './errors.js';

describe('OpenAICompatibleClient', () => {
  it('sends the request and maps a successful chat response', async () => {
    const fakeFetch = vi.fn(async () =>
      new Response(
        JSON.stringify({
          choices: [{ message: { content: 'hi from openai' }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 4, completion_tokens: 3 },
        }),
        { status: 200 }
      )
    );
    const client = new OpenAICompatibleClient('openai', 'https://api.openai.com/v1', 'sk-test', fakeFetch as unknown as typeof fetch);

    const response = await client.chat({
      providerId: 'openai-default',
      model: 'gpt-5',
      messages: [{ role: 'user', content: 'hi' }],
    });

    expect(response.content).toBe('hi from openai');
    expect(response.stopReason).toBe('end_turn');
    expect(response.usage).toEqual({ inputTokens: 4, outputTokens: 3 });
    expect(fakeFetch).toHaveBeenCalledWith(
      'https://api.openai.com/v1/chat/completions',
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer sk-test' }),
      })
    );
  });

  it('throws ProviderAuthError on a 401 response', async () => {
    const fakeFetch = vi.fn(async () => new Response('{}', { status: 401 }));
    const client = new OpenAICompatibleClient('openai', 'https://api.openai.com/v1', 'bad-key', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'openai-default', model: 'gpt-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderAuthError);
  });

  it('throws ProviderRateLimitError on a 429 response', async () => {
    const fakeFetch = vi.fn(async () => new Response('{}', { status: 429 }));
    const client = new OpenAICompatibleClient('openai', 'https://api.openai.com/v1', 'sk-test', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'openai-default', model: 'gpt-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderRateLimitError);
  });

  it('throws ProviderUnavailableError when the network request itself fails', async () => {
    const fakeFetch = vi.fn(async () => {
      throw new Error('ECONNREFUSED');
    });
    const client = new OpenAICompatibleClient('deepseek', 'https://api.deepseek.com/v1', 'sk-test', fakeFetch as unknown as typeof fetch);
    await expect(
      client.chat({ providerId: 'deepseek-default', model: 'deepseek-chat', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderUnavailableError);
  });

  it('lists models from the /models endpoint', async () => {
    const fakeFetch = vi.fn(async () => new Response(JSON.stringify({ data: [{ id: 'gpt-5' }, { id: 'gpt-5-mini' }] }), { status: 200 }));
    const client = new OpenAICompatibleClient('openai', 'https://api.openai.com/v1', 'sk-test', fakeFetch as unknown as typeof fetch);
    const models = await client.listModels();
    expect(models.map((m) => m.id)).toEqual(['gpt-5', 'gpt-5-mini']);
  });
});
```

`repos/server/src/providers/agentd-stub.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { AgentdBackedProviderClient } from './agentd-stub.js';
import { ProviderUnavailableError } from './errors.js';

describe('AgentdBackedProviderClient', () => {
  it('rejects chat with ProviderUnavailableError, never a faked success', async () => {
    const client = new AgentdBackedProviderClient('claude-subscription');
    await expect(
      client.chat({ providerId: 'my-claude-subscription', model: 'claude-sonnet-5', messages: [{ role: 'user', content: 'hi' }] })
    ).rejects.toThrow(ProviderUnavailableError);
  });

  it('rejects listModels with ProviderUnavailableError', async () => {
    const client = new AgentdBackedProviderClient('ollama');
    await expect(client.listModels()).rejects.toThrow(ProviderUnavailableError);
  });
});
```

`repos/server/src/providers/registry.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { AgentdBackedProviderClient } from './agentd-stub.js';
import { AnthropicClient } from './anthropic.js';
import { OpenAICompatibleClient } from './openai-compatible.js';
import { resolveProviderClient } from './registry.js';

describe('resolveProviderClient', () => {
  it('resolves an anthropic config to an AnthropicClient', () => {
    const client = resolveProviderClient({ id: 'a', kind: 'anthropic', apiKey: 'sk-test', baseUrl: null, createdAt: '', updatedAt: '' });
    expect(client).toBeInstanceOf(AnthropicClient);
  });

  it('resolves openai/openrouter/deepseek/openai-compatible configs to OpenAICompatibleClient', () => {
    for (const kind of ['openai', 'openrouter', 'deepseek'] as const) {
      const client = resolveProviderClient({ id: 'x', kind, apiKey: 'sk-test', baseUrl: null, createdAt: '', updatedAt: '' });
      expect(client).toBeInstanceOf(OpenAICompatibleClient);
      expect(client.kind).toBe(kind);
    }
    const compatible = resolveProviderClient({
      id: 'x',
      kind: 'openai-compatible',
      apiKey: 'sk-test',
      baseUrl: 'https://my-local-server/v1',
      createdAt: '',
      updatedAt: '',
    });
    expect(compatible).toBeInstanceOf(OpenAICompatibleClient);
  });

  it('resolves claude-subscription/ollama configs to AgentdBackedProviderClient', () => {
    for (const kind of ['claude-subscription', 'ollama'] as const) {
      const client = resolveProviderClient({ id: 'x', kind, apiKey: null, baseUrl: null, createdAt: '', updatedAt: '' });
      expect(client).toBeInstanceOf(AgentdBackedProviderClient);
    }
  });

  it('throws a plain config error (not a ProviderError) when a remote provider has no api key', () => {
    expect(() =>
      resolveProviderClient({ id: 'x', kind: 'anthropic', apiKey: null, baseUrl: null, createdAt: '', updatedAt: '' })
    ).toThrow(/missing an apiKey/);
  });

  it('throws a plain config error when an openai-compatible config has no baseUrl', () => {
    expect(() =>
      resolveProviderClient({ id: 'x', kind: 'openai-compatible', apiKey: 'sk-test', baseUrl: null, createdAt: '', updatedAt: '' })
    ).toThrow(/requires a baseUrl/);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/providers/openai-compatible.test.ts src/providers/agentd-stub.test.ts src/providers/registry.test.ts`
Expected: FAIL — modules do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/providers/openai-compatible.ts`:
```ts
import type { ChatRequest, ChatResponse, ModelInfo, ProviderKind } from '@opencrew/protocol';
import type { ProviderClient } from './client.js';
import { ProviderAuthError, ProviderRateLimitError, ProviderUnavailableError } from './errors.js';

interface OpenAiChatResponseBody {
  choices: { message: { content: string }; finish_reason: string }[];
  usage?: { prompt_tokens: number; completion_tokens: number };
}

interface OpenAiModelsResponseBody {
  data: { id: string }[];
}

export class OpenAICompatibleClient implements ProviderClient {
  constructor(
    public readonly kind: ProviderKind,
    private baseUrl: string,
    private apiKey: string,
    private fetchImpl: typeof fetch = fetch
  ) {}

  async chat(request: ChatRequest): Promise<ChatResponse> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}/chat/completions`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model: request.model,
          messages: request.messages.map((m) => ({ role: m.role, content: m.content })),
          max_tokens: request.maxTokens,
          temperature: request.temperature,
        }),
      });
    } catch (err) {
      throw new ProviderUnavailableError(`${this.kind} request failed: ${(err as Error).message}`);
    }

    if (response.status === 401 || response.status === 403) {
      throw new ProviderAuthError(`${this.kind} auth failed with status ${response.status}`);
    }
    if (response.status === 429) {
      throw new ProviderRateLimitError(`${this.kind} rate limited`);
    }
    if (!response.ok) {
      throw new ProviderUnavailableError(`${this.kind} returned status ${response.status}`);
    }

    const data = (await response.json()) as OpenAiChatResponseBody;
    const choice = data.choices[0];
    return {
      providerId: request.providerId,
      model: request.model,
      content: choice.message.content,
      stopReason: choice.finish_reason === 'stop' ? 'end_turn' : choice.finish_reason === 'length' ? 'max_tokens' : 'error',
      usage: {
        inputTokens: data.usage?.prompt_tokens ?? 0,
        outputTokens: data.usage?.completion_tokens ?? 0,
      },
    };
  }

  async listModels(): Promise<ModelInfo[]> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}/models`, {
        headers: { Authorization: `Bearer ${this.apiKey}` },
      });
    } catch (err) {
      throw new ProviderUnavailableError(`${this.kind} models request failed: ${(err as Error).message}`);
    }
    if (!response.ok) {
      throw new ProviderUnavailableError(`${this.kind} returned status ${response.status}`);
    }
    const data = (await response.json()) as OpenAiModelsResponseBody;
    return data.data.map((m) => ({ id: m.id, providerId: this.kind, displayName: m.id, contextWindow: 4096 }));
  }
}
```

`repos/server/src/providers/agentd-stub.ts`:
```ts
import type { ChatRequest, ChatResponse, ModelInfo, ProviderKind } from '@opencrew/protocol';
import type { ProviderClient } from './client.js';
import { ProviderUnavailableError } from './errors.js';

export class AgentdBackedProviderClient implements ProviderClient {
  constructor(public readonly kind: ProviderKind) {}

  async chat(_request: ChatRequest): Promise<ChatResponse> {
    throw new ProviderUnavailableError(
      `${this.kind} is agentd-backed and agentd is not yet available in this workspace`
    );
  }

  async listModels(): Promise<ModelInfo[]> {
    throw new ProviderUnavailableError(
      `${this.kind} is agentd-backed and agentd is not yet available in this workspace`
    );
  }
}
```

`repos/server/src/providers/registry.ts`:
```ts
import type { ProviderConfigRecord } from './repository.js';
import type { ProviderClient } from './client.js';
import { AgentdBackedProviderClient } from './agentd-stub.js';
import { AnthropicClient } from './anthropic.js';
import { OpenAICompatibleClient } from './openai-compatible.js';

const DEFAULT_BASE_URLS: Record<'openai' | 'openrouter' | 'deepseek', string> = {
  openai: 'https://api.openai.com/v1',
  openrouter: 'https://openrouter.ai/api/v1',
  deepseek: 'https://api.deepseek.com/v1',
};

export function resolveProviderClient(config: ProviderConfigRecord, fetchImpl: typeof fetch = fetch): ProviderClient {
  switch (config.kind) {
    case 'anthropic':
      if (!config.apiKey) throw new Error(`provider "${config.id}" is missing an apiKey`);
      return new AnthropicClient(config.apiKey, fetchImpl);
    case 'openai':
    case 'openrouter':
    case 'deepseek': {
      if (!config.apiKey) throw new Error(`provider "${config.id}" is missing an apiKey`);
      const baseUrl = config.baseUrl ?? DEFAULT_BASE_URLS[config.kind];
      return new OpenAICompatibleClient(config.kind, baseUrl, config.apiKey, fetchImpl);
    }
    case 'openai-compatible':
      if (!config.apiKey) throw new Error(`provider "${config.id}" is missing an apiKey`);
      if (!config.baseUrl) throw new Error(`provider "${config.id}" (openai-compatible) requires a baseUrl`);
      return new OpenAICompatibleClient('openai-compatible', config.baseUrl, config.apiKey, fetchImpl);
    case 'claude-subscription':
    case 'ollama':
      return new AgentdBackedProviderClient(config.kind);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/providers/openai-compatible.test.ts src/providers/agentd-stub.test.ts src/providers/registry.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/providers/openai-compatible.ts src/providers/openai-compatible.test.ts src/providers/agentd-stub.ts src/providers/agentd-stub.test.ts src/providers/registry.ts src/providers/registry.test.ts
git commit -m "feat: add OpenAI-compatible client, agentd-backed stub, and provider registry"
```

---

### Task 4: The RespondFn implementation with provider failure handling

**Files:**
- Create: `repos/server/src/providers/respond.ts`
- Test: `repos/server/src/providers/respond.test.ts`

**Interfaces:**
- Consumes: `RespondFn` type from `../runtime/engine.js` (unchanged — this
  task produces an IMPLEMENTATION of that existing type, not a new type).
  `getAgent` from `../agents/repository.js`. `getProviderConfig` from
  `./repository.js` (Task 1). `resolveProviderClient` from `./registry.js`
  (Task 3). `ProviderError` from `./errors.js` (Task 2).
- Produces: `createProviderRespond(db: Database.Database, fetchImpl?: typeof
  fetch): RespondFn` — this is what Task 5 wires into production, and what
  Task 6's e2e test constructs directly to prove the whole stack.

- [ ] **Step 1: Write the failing tests**

`repos/server/src/providers/respond.test.ts`:
```ts
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../db/connection.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';
import { createAgent } from '../agents/repository.js';
import { createProviderConfig } from './repository.js';
import { createProviderRespond } from './respond.js';

describe('createProviderRespond', () => {
  let dataDir: string;

  afterEach(() => {
    if (dataDir) fs.rmSync(dataDir, { recursive: true, force: true });
  });

  function freshSetup(modelPolicyExtra: { fallbackProviderId?: string; fallbackModel?: string } = {}) {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencrew-respond-'));
    const db = openDatabase(dataDir);
    runMigrations(db);
    const owner = createUser(db, { email: 'owner@example.com', displayName: 'Owner', passwordHash: 'x', role: 'owner' });
    const agent = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Assistant',
      personality: '',
      modelPolicy: { defaultProviderId: 'primary', defaultModel: 'model-a', ...modelPolicyExtra },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    return { db, owner, agent };
  }

  function jsonResponse(body: unknown, status = 200) {
    return new Response(JSON.stringify(body), { status });
  }

  const successBody = { content: [{ type: 'text', text: 'hi!' }], stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 1 } };

  it('returns the provider response body on success', async () => {
    const { db, agent } = freshSetup();
    createProviderConfig(db, { id: 'primary', kind: 'anthropic', apiKey: 'sk-test' });
    const respond = createProviderRespond(db, (async () => jsonResponse(successBody)) as unknown as typeof fetch);

    const result = await respond({ agentId: agent.id, conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toBe('hi!');
    db.close();
  });

  it('returns a safe error message when the primary provider is unavailable and no fallback is configured', async () => {
    const { db, agent } = freshSetup();
    createProviderConfig(db, { id: 'primary', kind: 'anthropic', apiKey: 'sk-test' });
    const respond = createProviderRespond(
      db,
      (async () => {
        throw new Error('ECONNREFUSED');
      }) as unknown as typeof fetch
    );

    const result = await respond({ agentId: agent.id, conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toContain('could not respond right now');
    db.close();
  });

  it('falls back to the fallback provider when the primary fails', async () => {
    const { db, agent } = freshSetup({ fallbackProviderId: 'backup', fallbackModel: 'model-b' });
    createProviderConfig(db, { id: 'primary', kind: 'anthropic', apiKey: 'sk-bad' });
    createProviderConfig(db, { id: 'backup', kind: 'anthropic', apiKey: 'sk-good' });
    let callCount = 0;
    const fakeFetch = (async () => {
      callCount += 1;
      if (callCount === 1) throw new Error('primary down');
      return jsonResponse({ content: [{ type: 'text', text: 'fallback here' }], stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 1 } });
    }) as unknown as typeof fetch;
    const respond = createProviderRespond(db, fakeFetch);

    const result = await respond({ agentId: agent.id, conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toBe('fallback here');
    expect(callCount).toBe(2);
    db.close();
  });

  it('returns a safe error message when both primary and fallback fail', async () => {
    const { db, agent } = freshSetup({ fallbackProviderId: 'backup', fallbackModel: 'model-b' });
    createProviderConfig(db, { id: 'primary', kind: 'anthropic', apiKey: 'sk-bad' });
    createProviderConfig(db, { id: 'backup', kind: 'anthropic', apiKey: 'sk-also-bad' });
    const respond = createProviderRespond(
      db,
      (async () => {
        throw new Error('down');
      }) as unknown as typeof fetch
    );

    const result = await respond({ agentId: agent.id, conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toContain('could not respond right now');
    db.close();
  });

  it('returns a safe error message when the agent does not exist', async () => {
    const { db } = freshSetup();
    const respond = createProviderRespond(db);
    const result = await respond({ agentId: 'nonexistent', conversationId: 'conversation_1', recentMessages: [] });
    expect(result.body).toContain('not found');
    db.close();
  });

  it('propagates a genuinely unexpected error instead of swallowing it', async () => {
    const { db, owner } = freshSetup();
    const agentWithBrokenProvider = createAgent(db, {
      ownerUserId: owner.id,
      name: 'Broken',
      personality: '',
      modelPolicy: { defaultProviderId: 'broken', defaultModel: 'model-a' },
      permissions: { tools: [], canMessageAgents: true, canApproveOwnActions: false },
    });
    createProviderConfig(db, { id: 'broken', kind: 'anthropic', apiKey: null });
    const respond = createProviderRespond(db);

    await expect(
      respond({ agentId: agentWithBrokenProvider.id, conversationId: 'conversation_1', recentMessages: [] })
    ).rejects.toThrow(/missing an apiKey/);
    db.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/server && npx vitest run src/providers/respond.test.ts`
Expected: FAIL — module does not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/server/src/providers/respond.ts`:
```ts
import type { ChatMessage, Message } from '@opencrew/protocol';
import type Database from 'better-sqlite3';
import { getAgent } from '../agents/repository.js';
import type { RespondFn } from '../runtime/engine.js';
import { ProviderError } from './errors.js';
import { getProviderConfig } from './repository.js';
import { resolveProviderClient } from './registry.js';

function toChatMessages(agentId: string, recentMessages: Message[]): ChatMessage[] {
  return recentMessages.map((m) => ({
    role: m.authorType === 'agent' && m.authorId === agentId ? 'assistant' : 'user',
    content: m.body,
  }));
}

async function chatViaProvider(
  db: Database.Database,
  providerId: string,
  model: string,
  messages: ChatMessage[],
  fetchImpl: typeof fetch
) {
  const config = getProviderConfig(db, providerId);
  if (!config) {
    throw new ProviderError(`no provider configured with id "${providerId}"`);
  }
  const client = resolveProviderClient(config, fetchImpl);
  return client.chat({ providerId, model, messages });
}

export function createProviderRespond(db: Database.Database, fetchImpl: typeof fetch = fetch): RespondFn {
  return async ({ agentId, recentMessages }) => {
    const agent = getAgent(db, agentId);
    if (!agent) {
      return { body: `[error] agent ${agentId} not found` };
    }

    const chatMessages = toChatMessages(agentId, recentMessages);

    try {
      const response = await chatViaProvider(
        db,
        agent.modelPolicy.defaultProviderId,
        agent.modelPolicy.defaultModel,
        chatMessages,
        fetchImpl
      );
      return { body: response.content };
    } catch (primaryError) {
      if (!(primaryError instanceof ProviderError)) throw primaryError;

      if (agent.modelPolicy.fallbackProviderId && agent.modelPolicy.fallbackModel) {
        try {
          const fallbackResponse = await chatViaProvider(
            db,
            agent.modelPolicy.fallbackProviderId,
            agent.modelPolicy.fallbackModel,
            chatMessages,
            fetchImpl
          );
          return { body: fallbackResponse.content };
        } catch (fallbackError) {
          if (!(fallbackError instanceof ProviderError)) throw fallbackError;
        }
      }

      return { body: `[error] agent ${agentId} could not respond right now: ${primaryError.message}` };
    }
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/server && npx vitest run src/providers/respond.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/providers/respond.ts src/providers/respond.test.ts
git commit -m "feat: add provider-backed RespondFn with fallback-provider failure handling"
```

---

### Task 5: Provider REST routes and production wiring

**Files:**
- Modify: `repos/server/src/permissions/model.ts`
- Create: `repos/server/src/providers/routes.ts`
- Test: `repos/server/src/providers/routes.test.ts`
- Modify: `repos/server/src/app.ts`
- Modify: `repos/server/src/index.ts`

**Interfaces:**
- Consumes: `createProviderConfig`, `listProviderConfigs`,
  `getProviderConfig` from Task 1. `resolveProviderClient` from Task 3.
  `createProviderRespond` from Task 4. `can`/`Role` from
  `../permissions/model.js`. `requireAuth` from `../auth/middleware.js`.
- Produces: `registerProviderRoutes(app: FastifyInstance): void` adding
  `POST /api/providers` (admin/owner only), `GET /api/providers`, and
  `GET /api/providers/:id/models`. Responses NEVER include `apiKey` — every
  response is redacted to `{ id, kind, baseUrl, createdAt, updatedAt,
  hasApiKey: boolean }`. `src/index.ts`'s production `main()` now passes
  `respond: createProviderRespond(db)` to `buildApp`.

- [ ] **Step 1: Write the failing tests**

Add `'provider:manage'` to `repos/server/src/permissions/model.ts`'s `Action`
union and `ACTION_MIN_ROLE` map (gated at `admin`, same tier as
`group:manage_members`) — this is a small addition to an existing file, no
test file changes needed (the existing `permissions/model.test.ts` doesn't
need a new case; the new action is exercised through the route test below).

`repos/server/src/providers/routes.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../app.js';
import { createSession } from '../auth/session.js';
import { runMigrations } from '../db/migrate.js';
import { createUser } from '../users/repository.js';

describe('provider routes', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
    vi.unstubAllGlobals();
  });

  async function setupOwner(app: Awaited<ReturnType<typeof buildApp>>) {
    const setup = await app.inject({
      method: 'POST',
      url: '/api/auth/setup',
      payload: { email: 'owner@example.com', displayName: 'Owner', password: 'super-secret-1' },
    });
    return setup.json().token as string;
  }

  it('lets an owner create a provider and never echoes the api key back', async () => {
    const app = await buildApp({ db });
    const token = await setupOwner(app);

    const create = await app.inject({
      method: 'POST',
      url: '/api/providers',
      headers: { authorization: `Bearer ${token}` },
      payload: { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-secret' },
    });
    expect(create.statusCode).toBe(201);
    expect(create.json().apiKey).toBeUndefined();
    expect(create.json().hasApiKey).toBe(true);

    await app.close();
  });

  it('rejects provider creation from a member-role user', async () => {
    const app = await buildApp({ db });
    await setupOwner(app);
    const member = createUser(db, { email: 'member@example.com', displayName: 'Member', passwordHash: 'x', role: 'member' });
    const memberToken = createSession(db, member.id);

    const create = await app.inject({
      method: 'POST',
      url: '/api/providers',
      headers: { authorization: `Bearer ${memberToken}` },
      payload: { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-secret' },
    });
    expect(create.statusCode).toBe(403);

    await app.close();
  });

  it('lists providers without api keys', async () => {
    const app = await buildApp({ db });
    const token = await setupOwner(app);
    await app.inject({
      method: 'POST',
      url: '/api/providers',
      headers: { authorization: `Bearer ${token}` },
      payload: { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-secret' },
    });

    const list = await app.inject({ method: 'GET', url: '/api/providers', headers: { authorization: `Bearer ${token}` } });
    expect(list.json()).toHaveLength(1);
    expect(list.json()[0].apiKey).toBeUndefined();

    await app.close();
  });

  it('returns 404 for models on an unknown provider', async () => {
    const app = await buildApp({ db });
    const token = await setupOwner(app);

    const models = await app.inject({
      method: 'GET',
      url: '/api/providers/nonexistent/models',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(models.statusCode).toBe(404);

    await app.close();
  });

  it('proxies GET /api/providers/:id/models for an anthropic provider (static list, no network)', async () => {
    const app = await buildApp({ db });
    const token = await setupOwner(app);
    await app.inject({
      method: 'POST',
      url: '/api/providers',
      headers: { authorization: `Bearer ${token}` },
      payload: { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-secret' },
    });

    const models = await app.inject({
      method: 'GET',
      url: '/api/providers/anthropic-default/models',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(models.statusCode).toBe(200);
    expect(models.json().length).toBeGreaterThan(0);

    await app.close();
  });

  it('returns 502 when a remote provider is unreachable while listing models', async () => {
    const app = await buildApp({ db });
    const token = await setupOwner(app);
    await app.inject({
      method: 'POST',
      url: '/api/providers',
      headers: { authorization: `Bearer ${token}` },
      payload: { id: 'openai-default', kind: 'openai', apiKey: 'sk-secret' },
    });

    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new Error('network down');
      })
    );

    const models = await app.inject({
      method: 'GET',
      url: '/api/providers/openai-default/models',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(models.statusCode).toBe(502);

    await app.close();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/server && npx vitest run src/providers/routes.test.ts`
Expected: FAIL — `./routes.js` doesn't exist, `/api/providers` returns 404.

- [ ] **Step 3: Write minimal implementation**

Update `repos/server/src/permissions/model.ts` (this file currently has
`export type { Role };` re-exporting `Role` — added by a fix wave during
the server-messaging-core plan to satisfy `tsc --noEmit` for
`conversations/routes.ts`'s `import { can, type Role } from
'../permissions/model.js'`. Read the file's CURRENT content first and only
add the `'provider:manage'` action and its `ACTION_MIN_ROLE` entry — do not
drop the `export type { Role };` line):
```ts
import type { Role } from '../users/repository.js';

export type { Role };

export type Action =
  | 'agent:create'
  | 'agent:manage'
  | 'conversation:create_group'
  | 'group:manage_members'
  | 'provider:manage';

const ROLE_RANK: Record<Role, number> = { member: 0, admin: 1, owner: 2 };

const ACTION_MIN_ROLE: Record<Action, Role> = {
  'agent:create': 'member',
  'agent:manage': 'member',
  'conversation:create_group': 'member',
  'group:manage_members': 'admin',
  'provider:manage': 'admin',
};

export function can(role: Role, action: Action): boolean {
  return ROLE_RANK[role] >= ROLE_RANK[ACTION_MIN_ROLE[action]];
}
```

`repos/server/src/providers/routes.ts`:
```ts
import { ProviderKindSchema } from '@opencrew/protocol';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireAuth } from '../auth/middleware.js';
import { can, type Role } from '../permissions/model.js';
import { createProviderConfig, getProviderConfig, listProviderConfigs, type ProviderConfigRecord } from './repository.js';
import { resolveProviderClient } from './registry.js';

const CreateProviderBodySchema = z.object({
  id: z.string().min(1),
  kind: ProviderKindSchema,
  apiKey: z.string().min(1).optional(),
  baseUrl: z.string().min(1).optional(),
});

function redact(config: ProviderConfigRecord) {
  const { apiKey, ...rest } = config;
  return { ...rest, hasApiKey: apiKey !== null };
}

export function registerProviderRoutes(app: FastifyInstance): void {
  app.post('/api/providers', { preHandler: requireAuth }, async (request, reply) => {
    if (!can(request.user!.role as Role, 'provider:manage')) {
      reply.code(403).send({ error: 'forbidden' });
      return;
    }
    const body = CreateProviderBodySchema.parse(request.body);
    const config = createProviderConfig(app.db, body);
    reply.code(201).send(redact(config));
  });

  app.get('/api/providers', { preHandler: requireAuth }, async (_request, reply) => {
    reply.send(listProviderConfigs(app.db).map(redact));
  });

  app.get('/api/providers/:id/models', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const config = getProviderConfig(app.db, id);
    if (!config) {
      reply.code(404).send({ error: 'provider_not_found' });
      return;
    }
    try {
      const client = resolveProviderClient(config);
      reply.send(await client.listModels());
    } catch (err) {
      reply.code(502).send({ error: 'provider_unavailable', message: (err as Error).message });
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
import { registerProviderRoutes } from './providers/routes.js';
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
  registerProviderRoutes(app);
  registerRuntimeRoutes(app, hub, opts.respond ?? defaultRespond);
  registerApprovalRoutes(app);
  registerWsRoutes(app, hub);

  return app;
}
```

Update `repos/server/src/index.ts`:
```ts
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { openDatabase } from './db/connection.js';
import { runMigrations } from './db/migrate.js';
import { createProviderRespond } from './providers/respond.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const db = openDatabase(config.dataDir);
  runMigrations(db);
  const app = await buildApp({ db, respond: createProviderRespond(db) });
  await app.listen({ port: config.port, host: '0.0.0.0' });
  console.log(`OpenCrew server listening on port ${config.port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

Note: `buildApp`'s default (`opts.respond ?? defaultRespond`) is
UNCHANGED — only the real production entry point (`index.ts`) now
constructs and passes a provider-backed `respond`. This keeps every
existing test that calls `buildApp({db})` with no `respond` option
working exactly as before (none of them invoke an agent turn without
explicitly supplying their own `respond`, so the default was never
actually exercised by them).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/server && npx vitest run src/providers/routes.test.ts`
Expected: PASS. Then run the FULL suite to confirm nothing regressed:
`cd repos/server && npm test`
Expected: all existing tests (across every earlier plan) still pass
unchanged.

- [ ] **Step 5: Commit**

```bash
cd repos/server
git add src/permissions/model.ts src/providers/routes.ts src/providers/routes.test.ts src/app.ts src/index.ts
git commit -m "feat: add provider REST routes and wire provider-backed respond into production"
```

---

### Task 6: End-to-end proof — real provider request shape and graceful failure through the full stack

**Files:**
- Create: `repos/server/test/provider-e2e.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1-5 (`buildApp`, `createProviderRespond`,
  `createProviderConfig`, the runtime/conversation/message/agent routes
  from earlier plans). No new production code — this proves the charter's
  "provider failure handling" testing minimum and that `provider.chat`
  (via `ChatRequest`/`ChatResponse`) has a real, exercised implementation
  for the remote-provider path.

- [ ] **Step 1: Write the test**

`repos/server/test/provider-e2e.test.ts`:
```ts
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { runMigrations } from '../src/db/migrate.js';
import { createProviderConfig } from '../src/providers/repository.js';
import { createProviderRespond } from '../src/providers/respond.js';

describe('provider end-to-end: real request shape through a configured provider, and graceful failure', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = new Database(':memory:');
    db.pragma('foreign_keys = ON');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  async function setupAgentAndConversation(app: Awaited<ReturnType<typeof buildApp>>) {
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
      payload: { name: 'Assistant', modelPolicy: { defaultProviderId: 'anthropic-default', defaultModel: 'claude-sonnet-5' } },
    });
    const agentId = createAgent.json().id as string;

    const dm = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      headers: { authorization: `Bearer ${token}` },
      payload: { participantId: agentId, participantType: 'agent' },
    });

    return { token, agentId, conversationId: dm.json().id as string };
  }

  it('invokes an agent whose response comes from a real provider request/response round-trip', async () => {
    createProviderConfig(db, { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-test' });
    let capturedBody: { model: string } | undefined;
    const fakeFetch = (async (_url: string, init: RequestInit) => {
      capturedBody = JSON.parse(init.body as string);
      return new Response(
        JSON.stringify({
          content: [{ type: 'text', text: 'Real provider response!' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 3, output_tokens: 3 },
        }),
        { status: 200 }
      );
    }) as unknown as typeof fetch;

    const app = await buildApp({ db, respond: createProviderRespond(db, fakeFetch) });
    const { token, agentId, conversationId } = await setupAgentAndConversation(app);

    const invoke = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: { conversationId },
    });
    expect(invoke.statusCode).toBe(201);
    expect(invoke.json().message.body).toBe('Real provider response!');
    expect(capturedBody?.model).toBe('claude-sonnet-5');

    await app.close();
  });

  it('degrades gracefully to a safe persisted message instead of a 500 when the provider is unreachable', async () => {
    createProviderConfig(db, { id: 'anthropic-default', kind: 'anthropic', apiKey: 'sk-test' });
    const fakeFetch = (async () => {
      throw new Error('network down');
    }) as unknown as typeof fetch;

    const app = await buildApp({ db, respond: createProviderRespond(db, fakeFetch) });
    const { token, agentId, conversationId } = await setupAgentAndConversation(app);

    const invoke = await app.inject({
      method: 'POST',
      url: `/api/agents/${agentId}/runs`,
      headers: { authorization: `Bearer ${token}` },
      payload: { conversationId },
    });
    expect(invoke.statusCode).toBe(201);
    expect(invoke.json().message.body).toContain('could not respond right now');

    const messages = await app.inject({
      method: 'GET',
      url: `/api/conversations/${conversationId}/messages`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(messages.json()).toHaveLength(1);

    await app.close();
  });
});
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd repos/server && npx vitest run test/provider-e2e.test.ts`
Expected: PASS on the first run — every piece was already built and tested
in isolation by Tasks 1-5; this test proves the integration, which is new
information even though no new production code is written. If it fails,
that reveals an integration gap between two "complete" earlier tasks; fix
the bug in whichever task's files are implicated, re-run that task's own
test file to confirm no regression, then re-run this test.

- [ ] **Step 3: Run the full suite, tsc, and the build; smoke-test the production entrypoint**

```bash
cd repos/server
npm test
npx tsc -p tsconfig.json --noEmit
npm run build
node dist/index.js &
sleep 1
curl -s http://localhost:4000/api/health
kill %1
```

Expected: every test file passes; `tsc --noEmit` is clean; `npm run build`
succeeds with `dist/` containing no test files and all 11 migrations
(`0001`-`0011`); the built server boots (via `index.ts`'s now-provider-aware
`main()`) and responds `{"ok":true}` on `/api/health` even with zero
providers configured, proving the "no mandatory external services" and
"boots with zero providers configured" constraints hold for the actual
shipped artifact, not just the test-only path. On Windows, if backgrounding
with `&`/`kill %1` doesn't behave as expected in your shell, start the
process, curl it from a second terminal or a short-lived script, then stop
it manually — the important evidence is the `{"ok":true}` response, not the
exact shell incantation.

- [ ] **Step 4: Commit**

```bash
cd repos/server
git add test/provider-e2e.test.ts
git commit -m "test: prove provider request shape and graceful failure handling end-to-end"
```

---

## What this plan deliberately leaves out

- **A real agentd client for Claude Subscription/Ollama.** agentd doesn't
  exist in this workspace yet. **DEV B REQUEST** (not yet needed, noted for
  when agentd exists): once agentd is available, `AgentdBackedProviderClient`
  needs a real implementation of `chat()`/`listModels()` that sends exactly
  the `provider.chat`/`provider.models` operations already defined in
  `@opencrew/protocol`'s `AgentdRequestSchema`/`AgentdResponseSchema`
  (`repos/protocol/src/schemas/agentd.ts`) over whatever transport agentd
  exposes — this plan's job was only to make sure those two provider kinds
  are valid, storable, and fail loudly rather than fake success in the
  meantime.
- **Streaming responses.** `ChatResponse` (and this plan's clients) return
  one complete response, not a token stream. Real-time streaming to the
  WebSocket layer is a reasonable future enhancement but wasn't asked for
  and would touch the `ConnectionHub`/`runAgentTurn` contract in ways this
  plan's scope doesn't cover.
- **Automatic retry with backoff, circuit breaking, or usage/cost
  tracking.** The one-shot fallback-provider retry in `createProviderRespond`
  is the extent of this plan's failure handling; anything more elaborate
  (exponential backoff, per-provider circuit breakers, token/cost budgets)
  is real future work, not implied by the charter's "failure handling"
  testing minimum.
- **Per-user or per-agent provider credentials.** Provider configs are
  server-wide, matching the charter's "extremely lightweight self-host"
  goal for v0.1 (one self-hosted instance, one set of keys). A multi-tenant
  credentials model is a different product shape nobody has asked for yet.
- **Dynamic model-capability metadata beyond a display name and a
  best-effort context window.** `ModelInfo.contextWindow` for
  OpenAI-compatible providers is a documented placeholder (`4096`) since
  their generic `/models` endpoints don't reliably return this figure —
  accurate per-model context windows would need a maintained lookup table,
  out of scope here.
