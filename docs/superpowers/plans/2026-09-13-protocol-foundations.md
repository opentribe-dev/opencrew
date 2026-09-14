# Protocol Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `repos/protocol` (`@opencrew/protocol`), the vendor-neutral TypeScript
+ Zod schema package that every other OpenCrew repo (server, sdk, and eventually
agentd/app) imports for shared types: Agent, RuntimeBinding/RuntimeSession, Conversation,
Message, Provider, agentd operation envelope, MemoryFact, WebSocket envelope, Approval.

**Architecture:** A single small npm package with no runtime dependency beyond `zod`.
Each domain gets its own schema module under `src/schemas/`; every schema is a Zod
object exported alongside its inferred TypeScript type, so consumers get both runtime
validation and compile-time types from one definition. `src/index.ts` re-exports
everything. Consumers (server, sdk) depend on it via a `file:../protocol` path
dependency — there is no package registry in v0.1.

**Tech Stack:** TypeScript 5, Zod 3, Vitest 2, built with `tsc` (no bundler needed for
a types-only package).

**Spec:** `docs/specs/2026-09-13-opencrew-backend-charter.md`

## Global Constraints

- Vendor-specific session IDs must never live directly on the core Agent model (put
  them on `RuntimeBinding.vendorState` instead).
- Agent != Model != Runtime != Runtime Session; `RuntimeSession = Agent + Conversation
  + Runtime + Workspace`.
- Agent-to-agent runs carry `rootRunId`, `causationId`, `hopCount`; default max hop
  count is 4.
- agentd operations are high-level (`runtime.run`, `runtime.resume`, `provider.chat`,
  `provider.models`, `workspace.list`, `approval.respond`) — never arbitrary shell.
- Provider kinds must include both remote (anthropic, openai, openrouter, deepseek,
  openai-compatible) and agentd-backed local (claude-subscription, ollama) kinds.
- MemoryFacts must be representable as inspectable/editable/deletable/deduplicated
  records (tags + content, no vector-DB-only fields).
- Contracts must stay vendor-neutral and versioned (`PROTOCOL_VERSION`).

---

## File Structure

```
repos/protocol/
  package.json
  tsconfig.json
  vitest.config.ts
  .gitignore
  README.md
  AGENTS.md
  CLAUDE.md
  src/
    version.ts
    version.test.ts
    schemas/
      agent.ts
      agent.test.ts
      runtime.ts
      runtime.test.ts
      conversation.ts
      conversation.test.ts
      message.ts
      message.test.ts
      provider.ts
      provider.test.ts
      agentd.ts
      agentd.test.ts
      memory.ts
      memory.test.ts
      websocket.ts
      websocket.test.ts
      approval.ts
      approval.test.ts
    index.ts
    index.test.ts
```

---

### Task 1: Bootstrap the `@opencrew/protocol` package

**Files:**
- Create: `repos/protocol/package.json`
- Create: `repos/protocol/tsconfig.json`
- Create: `repos/protocol/vitest.config.ts`
- Create: `repos/protocol/.gitignore`
- Create: `repos/protocol/README.md`
- Create: `repos/protocol/AGENTS.md`
- Create: `repos/protocol/CLAUDE.md`
- Create: `repos/protocol/src/index.ts`

**Interfaces:**
- Produces: an installable local package at `repos/protocol` that later tasks add
  schema modules to, and that `repos/server` (server-foundations plan) depends on via
  `"@opencrew/protocol": "file:../protocol"`.

- [ ] **Step 1: Initialize the git repo and directory (from the OpenCrew workspace root, NOT inside `repos/server`)**

```bash
cd repos
mkdir protocol
cd protocol
git init -b main
```

- [ ] **Step 2: Create the scaffold files**

`repos/protocol/README.md`:
```markdown
# OpenCrew protocol

Vendor-neutral protocol schemas and contracts shared by every OpenCrew repository.
Part of https://github.com/opentribe-dev.
```

`repos/protocol/AGENTS.md` (and identical `CLAUDE.md`):
```markdown
# OpenCrew protocol

This is an independent Git repository inside the OpenCrew multi-repo workspace.
Keep changes scoped to this component and coordinate protocol changes across affected repos.

Owned by Developer A (backend/protocol/core runtime). Keep schemas vendor-neutral:
no vendor-specific session IDs on the Agent schema, no implementation details from
any single runtime or provider leaking into shared types.
```

`repos/protocol/.gitignore`:
```
node_modules/
dist/
```

`repos/protocol/package.json`:
```json
{
  "name": "@opencrew/protocol",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.js"
    }
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "typescript": "^5.6.3",
    "vitest": "^2.1.4"
  },
  "engines": {
    "node": ">=20"
  }
}
```

`repos/protocol/tsconfig.json`:
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
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`repos/protocol/vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
  },
});
```

`repos/protocol/src/index.ts`:
```ts
export {};
```

- [ ] **Step 3: Install dependencies and verify the build succeeds**

```bash
cd repos/protocol
npm install
npm run build
```

Expected: `dist/index.js` and `dist/index.d.ts` are created, no TypeScript errors.

- [ ] **Step 4: Commit**

```bash
cd repos/protocol
git add -A
git commit -m "chore: bootstrap @opencrew/protocol package"
```

---

### Task 2: Protocol version constant

**Files:**
- Create: `repos/protocol/src/version.ts`
- Test: `repos/protocol/src/version.test.ts`

**Interfaces:**
- Produces: `PROTOCOL_VERSION: string` — a semver string every later schema module
  and the server/sdk can reference for compatibility checks.

- [ ] **Step 1: Write the failing test**

`repos/protocol/src/version.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { PROTOCOL_VERSION } from './version.js';

describe('PROTOCOL_VERSION', () => {
  it('is a semver string', () => {
    expect(PROTOCOL_VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/protocol && npx vitest run src/version.test.ts`
Expected: FAIL — `Cannot find module './version.js'`

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/version.ts`:
```ts
export const PROTOCOL_VERSION = '0.1.0';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/protocol && npx vitest run src/version.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/version.ts src/version.test.ts
git commit -m "feat: add PROTOCOL_VERSION constant"
```

---

### Task 3: Agent and Runtime schemas

**Files:**
- Create: `repos/protocol/src/schemas/agent.ts`
- Create: `repos/protocol/src/schemas/agent.test.ts`
- Create: `repos/protocol/src/schemas/runtime.ts`
- Create: `repos/protocol/src/schemas/runtime.test.ts`

**Interfaces:**
- Produces: `AgentSchema`/`Agent`, `ModelPolicySchema`/`ModelPolicy`,
  `PermissionSetSchema`/`PermissionSet`, `RelationshipRefSchema`/`RelationshipRef`,
  `FORBIDDEN_AGENT_FIELDS` (const array of vendor-session-id-shaped keys, used only
  in tests to document the invariant). `RuntimeKindSchema`/`RuntimeKind`,
  `RuntimeBindingSchema`/`RuntimeBinding` (holds `vendorState: Record<string, unknown>`
  for vendor session IDs), `RuntimeSessionSchema`/`RuntimeSession`,
  `DEFAULT_MAX_HOP_COUNT` (= 4), `AgentRunSchema`/`AgentRun` (carries `rootRunId`,
  `causationId`, `hopCount`).
- Consumes: nothing outside this task (first domain schemas in the package).

This is the task that encodes the "Agent != Runtime != Runtime Session" and
"vendor-specific session IDs never live on Agent" invariants, so both schema files are
reviewed together.

- [ ] **Step 1: Write the failing tests**

`repos/protocol/src/schemas/agent.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { AgentSchema, FORBIDDEN_AGENT_FIELDS } from './agent.js';

const validAgent = {
  id: 'agent_1',
  ownerUserId: 'user_1',
  name: 'Researcher',
  personality: 'Curious and terse.',
  modelPolicy: { defaultProviderId: 'anthropic', defaultModel: 'claude-sonnet-5' },
  permissions: { tools: ['web_search'], canMessageAgents: true, canApproveOwnActions: false },
  relationships: [{ agentId: 'agent_2', label: 'collaborator' }],
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
};

describe('AgentSchema', () => {
  it('parses a valid agent', () => {
    expect(() => AgentSchema.parse(validAgent)).not.toThrow();
  });

  it('applies default permissions/relationships when omitted', () => {
    const { relationships, ...withoutRelationships } = validAgent;
    const parsed = AgentSchema.parse(withoutRelationships);
    expect(parsed.relationships).toEqual([]);
  });

  it.each(FORBIDDEN_AGENT_FIELDS)('rejects vendor session field %s on the core Agent model', (field) => {
    const tainted = { ...validAgent, [field]: 'vendor-specific-value' };
    expect(() => AgentSchema.parse(tainted)).toThrow();
  });
});
```

`repos/protocol/src/schemas/runtime.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import {
  AgentRunSchema,
  DEFAULT_MAX_HOP_COUNT,
  RuntimeBindingSchema,
  RuntimeSessionSchema,
} from './runtime.js';

describe('DEFAULT_MAX_HOP_COUNT', () => {
  it('is 4', () => {
    expect(DEFAULT_MAX_HOP_COUNT).toBe(4);
  });
});

describe('RuntimeBindingSchema', () => {
  it('stores vendor-specific session state off the Agent model', () => {
    const binding = RuntimeBindingSchema.parse({
      id: 'binding_1',
      agentId: 'agent_1',
      runtimeKind: 'claude-code',
      workspacePath: '/workspaces/agent_1',
      vendorState: { claudeSessionId: 'sess_abc123' },
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    });
    expect(binding.vendorState.claudeSessionId).toBe('sess_abc123');
  });

  it('rejects unknown runtime kinds', () => {
    expect(() =>
      RuntimeBindingSchema.parse({
        id: 'binding_1',
        agentId: 'agent_1',
        runtimeKind: 'not-a-real-runtime',
        workspacePath: '/workspaces/agent_1',
        vendorState: {},
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
      })
    ).toThrow();
  });
});

describe('RuntimeSessionSchema', () => {
  it('composes Agent + Conversation + Runtime + Workspace via foreign keys', () => {
    const session = RuntimeSessionSchema.parse({
      id: 'session_1',
      agentId: 'agent_1',
      conversationId: 'conversation_1',
      runtimeBindingId: 'binding_1',
      status: 'running',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    });
    expect(session.status).toBe('running');
  });
});

describe('AgentRunSchema', () => {
  it('rejects hopCount above DEFAULT_MAX_HOP_COUNT', () => {
    expect(() =>
      AgentRunSchema.parse({
        runId: 'run_2',
        rootRunId: 'run_1',
        causationId: 'run_1',
        hopCount: DEFAULT_MAX_HOP_COUNT + 1,
        agentId: 'agent_1',
        conversationId: 'conversation_1',
        createdAt: '2026-01-01T00:00:00.000Z',
      })
    ).toThrow();
  });

  it('accepts a root run with hopCount 0 and null causationId', () => {
    const run = AgentRunSchema.parse({
      runId: 'run_1',
      rootRunId: 'run_1',
      causationId: null,
      hopCount: 0,
      agentId: 'agent_1',
      conversationId: 'conversation_1',
      createdAt: '2026-01-01T00:00:00.000Z',
    });
    expect(run.hopCount).toBe(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/protocol && npx vitest run src/schemas/agent.test.ts src/schemas/runtime.test.ts`
Expected: FAIL — modules `./agent.js` and `./runtime.js` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/schemas/agent.ts`:
```ts
import { z } from 'zod';

export const ModelPolicySchema = z.object({
  defaultProviderId: z.string().min(1),
  defaultModel: z.string().min(1),
  fallbackProviderId: z.string().min(1).optional(),
  fallbackModel: z.string().min(1).optional(),
});
export type ModelPolicy = z.infer<typeof ModelPolicySchema>;

export const PermissionSetSchema = z.object({
  tools: z.array(z.string()).default([]),
  canMessageAgents: z.boolean().default(true),
  canApproveOwnActions: z.boolean().default(false),
});
export type PermissionSet = z.infer<typeof PermissionSetSchema>;

export const RelationshipRefSchema = z.object({
  agentId: z.string().min(1),
  label: z.string().min(1),
});
export type RelationshipRef = z.infer<typeof RelationshipRefSchema>;

export const AgentSchema = z
  .object({
    id: z.string().min(1),
    ownerUserId: z.string().min(1),
    name: z.string().min(1),
    personality: z.string().default(''),
    modelPolicy: ModelPolicySchema,
    permissions: PermissionSetSchema,
    relationships: z.array(RelationshipRefSchema).default([]),
    createdAt: z.string().datetime(),
    updatedAt: z.string().datetime(),
  })
  .strict();
export type Agent = z.infer<typeof AgentSchema>;

/**
 * Field names a runtime integration might be tempted to bolt onto Agent directly.
 * AgentSchema is `.strict()`, so any object carrying one of these fails to parse —
 * vendor session state belongs on RuntimeBinding.vendorState instead.
 */
export const FORBIDDEN_AGENT_FIELDS = [
  'runtimeSessionId',
  'claudeSessionId',
  'codexSessionId',
  'geminiSessionId',
  'vendorSessionId',
  'runtimeId',
  'threadId',
] as const;
```

`repos/protocol/src/schemas/runtime.ts`:
```ts
import { z } from 'zod';

export const RuntimeKindSchema = z.enum(['native', 'claude-code', 'codex', 'gemini-cli']);
export type RuntimeKind = z.infer<typeof RuntimeKindSchema>;

export const RuntimeBindingSchema = z.object({
  id: z.string().min(1),
  agentId: z.string().min(1),
  runtimeKind: RuntimeKindSchema,
  workspacePath: z.string().min(1),
  vendorState: z.record(z.string(), z.unknown()).default({}),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
});
export type RuntimeBinding = z.infer<typeof RuntimeBindingSchema>;

export const RuntimeSessionStatusSchema = z.enum([
  'idle',
  'running',
  'waiting_approval',
  'error',
  'closed',
]);
export type RuntimeSessionStatus = z.infer<typeof RuntimeSessionStatusSchema>;

export const RuntimeSessionSchema = z.object({
  id: z.string().min(1),
  agentId: z.string().min(1),
  conversationId: z.string().min(1),
  runtimeBindingId: z.string().min(1),
  status: RuntimeSessionStatusSchema,
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
});
export type RuntimeSession = z.infer<typeof RuntimeSessionSchema>;

export const DEFAULT_MAX_HOP_COUNT = 4;

export const AgentRunSchema = z.object({
  runId: z.string().min(1),
  rootRunId: z.string().min(1),
  causationId: z.string().min(1).nullable(),
  hopCount: z.number().int().min(0).max(DEFAULT_MAX_HOP_COUNT),
  agentId: z.string().min(1),
  conversationId: z.string().min(1),
  createdAt: z.string().datetime(),
});
export type AgentRun = z.infer<typeof AgentRunSchema>;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/protocol && npx vitest run src/schemas/agent.test.ts src/schemas/runtime.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/schemas/agent.ts src/schemas/agent.test.ts src/schemas/runtime.ts src/schemas/runtime.test.ts
git commit -m "feat: add Agent and Runtime schemas with vendor-session-id invariant"
```

---

### Task 4: Conversation and Message schemas

**Files:**
- Create: `repos/protocol/src/schemas/conversation.ts`
- Create: `repos/protocol/src/schemas/conversation.test.ts`
- Create: `repos/protocol/src/schemas/message.ts`
- Create: `repos/protocol/src/schemas/message.test.ts`

**Interfaces:**
- Produces: `ConversationKindSchema`/`ConversationKind` (`'dm' | 'group'`),
  `ParticipantRefSchema`/`ParticipantRef`, `ConversationSchema`/`Conversation`.
  `MentionRefSchema`/`MentionRef`, `MessageSchema`/`Message` (carries
  `replyToMessageId: string | null`).
- Consumes: nothing from Task 3 directly (participant/author ids are opaque strings
  at the protocol layer; the server plan is responsible for ensuring they resolve to
  real users/agents).

- [ ] **Step 1: Write the failing tests**

`repos/protocol/src/schemas/conversation.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { ConversationSchema } from './conversation.js';

const now = '2026-01-01T00:00:00.000Z';

describe('ConversationSchema', () => {
  it('parses a valid dm with exactly two participants', () => {
    const dm = ConversationSchema.parse({
      id: 'conversation_1',
      kind: 'dm',
      name: null,
      participants: [
        { participantId: 'user_1', participantType: 'user' },
        { participantId: 'agent_1', participantType: 'agent' },
      ],
      createdAt: now,
      updatedAt: now,
    });
    expect(dm.participants).toHaveLength(2);
  });

  it('rejects a group conversation without a name', () => {
    expect(() =>
      ConversationSchema.parse({
        id: 'conversation_2',
        kind: 'group',
        name: null,
        participants: [
          { participantId: 'user_1', participantType: 'user' },
          { participantId: 'user_2', participantType: 'user' },
        ],
        createdAt: now,
        updatedAt: now,
      })
    ).toThrow();
  });

  it('rejects a conversation with fewer than two participants', () => {
    expect(() =>
      ConversationSchema.parse({
        id: 'conversation_3',
        kind: 'dm',
        name: null,
        participants: [{ participantId: 'user_1', participantType: 'user' }],
        createdAt: now,
        updatedAt: now,
      })
    ).toThrow();
  });
});
```

`repos/protocol/src/schemas/message.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { MessageSchema } from './message.js';

const now = '2026-01-01T00:00:00.000Z';

describe('MessageSchema', () => {
  it('parses a message with a mention and a reply', () => {
    const message = MessageSchema.parse({
      id: 'message_2',
      conversationId: 'conversation_1',
      authorId: 'agent_1',
      authorType: 'agent',
      body: '@user_1 following up on that',
      mentions: [{ targetId: 'user_1', targetType: 'user' }],
      replyToMessageId: 'message_1',
      createdAt: now,
    });
    expect(message.replyToMessageId).toBe('message_1');
  });

  it('defaults mentions to an empty array and allows a null replyToMessageId', () => {
    const message = MessageSchema.parse({
      id: 'message_1',
      conversationId: 'conversation_1',
      authorId: 'user_1',
      authorType: 'user',
      body: 'hello',
      replyToMessageId: null,
      createdAt: now,
    });
    expect(message.mentions).toEqual([]);
  });

  it('rejects an empty body', () => {
    expect(() =>
      MessageSchema.parse({
        id: 'message_3',
        conversationId: 'conversation_1',
        authorId: 'user_1',
        authorType: 'user',
        body: '',
        replyToMessageId: null,
        createdAt: now,
      })
    ).toThrow();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/protocol && npx vitest run src/schemas/conversation.test.ts src/schemas/message.test.ts`
Expected: FAIL — modules do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/schemas/conversation.ts`:
```ts
import { z } from 'zod';

export const ConversationKindSchema = z.enum(['dm', 'group']);
export type ConversationKind = z.infer<typeof ConversationKindSchema>;

export const ParticipantRefSchema = z.object({
  participantId: z.string().min(1),
  participantType: z.enum(['user', 'agent']),
});
export type ParticipantRef = z.infer<typeof ParticipantRefSchema>;

export const ConversationSchema = z
  .object({
    id: z.string().min(1),
    kind: ConversationKindSchema,
    name: z.string().min(1).nullable(),
    participants: z.array(ParticipantRefSchema).min(2),
    createdAt: z.string().datetime(),
    updatedAt: z.string().datetime(),
  })
  .refine((c) => c.kind !== 'group' || c.name !== null, {
    message: 'group conversations require a name',
    path: ['name'],
  });
export type Conversation = z.infer<typeof ConversationSchema>;
```

`repos/protocol/src/schemas/message.ts`:
```ts
import { z } from 'zod';

export const MentionRefSchema = z.object({
  targetId: z.string().min(1),
  targetType: z.enum(['user', 'agent']),
});
export type MentionRef = z.infer<typeof MentionRefSchema>;

export const MessageSchema = z.object({
  id: z.string().min(1),
  conversationId: z.string().min(1),
  authorId: z.string().min(1),
  authorType: z.enum(['user', 'agent']),
  body: z.string().min(1),
  mentions: z.array(MentionRefSchema).default([]),
  replyToMessageId: z.string().min(1).nullable(),
  createdAt: z.string().datetime(),
});
export type Message = z.infer<typeof MessageSchema>;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/protocol && npx vitest run src/schemas/conversation.test.ts src/schemas/message.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/schemas/conversation.ts src/schemas/conversation.test.ts src/schemas/message.ts src/schemas/message.test.ts
git commit -m "feat: add Conversation and Message schemas"
```

---

### Task 5: Provider and agentd operation schemas

**Files:**
- Create: `repos/protocol/src/schemas/provider.ts`
- Create: `repos/protocol/src/schemas/provider.test.ts`
- Create: `repos/protocol/src/schemas/agentd.ts`
- Create: `repos/protocol/src/schemas/agentd.test.ts`

**Interfaces:**
- Produces: `ProviderKindSchema`/`ProviderKind`, `REMOTE_PROVIDER_KINDS`,
  `AGENTD_BACKED_PROVIDER_KINDS`, `ChatMessageSchema`/`ChatMessage`,
  `ChatRequestSchema`/`ChatRequest`, `ChatResponseSchema`/`ChatResponse`,
  `ModelInfoSchema`/`ModelInfo`. `AgentdOperationNameSchema`/`AgentdOperationName`
  (the six high-level ops), `AgentdRequestSchema`/`AgentdRequest`,
  `AgentdResponseSchema`/`AgentdResponse`, `AgentdEventSchema`/`AgentdEvent`.
- Consumes: nothing from earlier tasks.

Reviewed together because the agentd envelope's `payload`/`result` are transport for
provider chat/model requests — the two are one contract surface.

- [ ] **Step 1: Write the failing tests**

`repos/protocol/src/schemas/provider.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import {
  AGENTD_BACKED_PROVIDER_KINDS,
  ChatRequestSchema,
  ChatResponseSchema,
  ProviderKindSchema,
  REMOTE_PROVIDER_KINDS,
} from './provider.js';

describe('ProviderKindSchema', () => {
  it('accepts every documented remote and agentd-backed kind', () => {
    for (const kind of [...REMOTE_PROVIDER_KINDS, ...AGENTD_BACKED_PROVIDER_KINDS]) {
      expect(() => ProviderKindSchema.parse(kind)).not.toThrow();
    }
  });

  it('includes claude-subscription and ollama as agentd-backed, not remote', () => {
    expect(AGENTD_BACKED_PROVIDER_KINDS).toContain('claude-subscription');
    expect(AGENTD_BACKED_PROVIDER_KINDS).toContain('ollama');
    expect(REMOTE_PROVIDER_KINDS).not.toContain('claude-subscription');
  });
});

describe('ChatRequestSchema / ChatResponseSchema', () => {
  it('round-trips a minimal chat exchange', () => {
    const request = ChatRequestSchema.parse({
      providerId: 'anthropic-default',
      model: 'claude-sonnet-5',
      messages: [{ role: 'user', content: 'hello' }],
    });
    expect(request.messages).toHaveLength(1);

    const response = ChatResponseSchema.parse({
      providerId: 'anthropic-default',
      model: 'claude-sonnet-5',
      content: 'hi there',
      stopReason: 'end_turn',
      usage: { inputTokens: 3, outputTokens: 3 },
    });
    expect(response.stopReason).toBe('end_turn');
  });

  it('rejects a chat request with zero messages', () => {
    expect(() =>
      ChatRequestSchema.parse({ providerId: 'anthropic-default', model: 'claude-sonnet-5', messages: [] })
    ).toThrow();
  });
});
```

`repos/protocol/src/schemas/agentd.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { AgentdOperationNameSchema, AgentdRequestSchema, AgentdResponseSchema } from './agentd.js';

describe('AgentdOperationNameSchema', () => {
  it('only allows the six documented high-level operations', () => {
    const allowed = [
      'runtime.run',
      'runtime.resume',
      'provider.chat',
      'provider.models',
      'workspace.list',
      'approval.respond',
    ];
    for (const op of allowed) {
      expect(() => AgentdOperationNameSchema.parse(op)).not.toThrow();
    }
    expect(() => AgentdOperationNameSchema.parse('shell.exec')).toThrow();
  });
});

describe('AgentdRequestSchema / AgentdResponseSchema', () => {
  it('parses a runtime.run request and a matching success response', () => {
    const request = AgentdRequestSchema.parse({
      requestId: 'req_1',
      operation: 'runtime.run',
      payload: { agentId: 'agent_1', conversationId: 'conversation_1' },
    });
    expect(request.operation).toBe('runtime.run');

    const response = AgentdResponseSchema.parse({
      requestId: 'req_1',
      ok: true,
      result: { runId: 'run_1' },
    });
    expect(response.ok).toBe(true);
  });

  it('parses a failure response carrying a structured error', () => {
    const response = AgentdResponseSchema.parse({
      requestId: 'req_2',
      ok: false,
      error: { code: 'provider_unavailable', message: 'no internet connection' },
    });
    expect(response.error?.code).toBe('provider_unavailable');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/protocol && npx vitest run src/schemas/provider.test.ts src/schemas/agentd.test.ts`
Expected: FAIL — modules do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/schemas/provider.ts`:
```ts
import { z } from 'zod';

export const REMOTE_PROVIDER_KINDS = [
  'anthropic',
  'openai',
  'openrouter',
  'deepseek',
  'openai-compatible',
] as const;

export const AGENTD_BACKED_PROVIDER_KINDS = ['claude-subscription', 'ollama'] as const;

export const ProviderKindSchema = z.enum([...REMOTE_PROVIDER_KINDS, ...AGENTD_BACKED_PROVIDER_KINDS]);
export type ProviderKind = z.infer<typeof ProviderKindSchema>;

export const ChatMessageSchema = z.object({
  role: z.enum(['system', 'user', 'assistant']),
  content: z.string(),
});
export type ChatMessage = z.infer<typeof ChatMessageSchema>;

export const ChatRequestSchema = z.object({
  providerId: z.string().min(1),
  model: z.string().min(1),
  messages: z.array(ChatMessageSchema).min(1),
  maxTokens: z.number().int().positive().optional(),
  temperature: z.number().min(0).max(2).optional(),
});
export type ChatRequest = z.infer<typeof ChatRequestSchema>;

export const ChatResponseSchema = z.object({
  providerId: z.string().min(1),
  model: z.string().min(1),
  content: z.string(),
  stopReason: z.enum(['end_turn', 'max_tokens', 'error']),
  usage: z.object({
    inputTokens: z.number().int().min(0),
    outputTokens: z.number().int().min(0),
  }),
});
export type ChatResponse = z.infer<typeof ChatResponseSchema>;

export const ModelInfoSchema = z.object({
  id: z.string().min(1),
  providerId: z.string().min(1),
  displayName: z.string().min(1),
  contextWindow: z.number().int().positive(),
});
export type ModelInfo = z.infer<typeof ModelInfoSchema>;
```

`repos/protocol/src/schemas/agentd.ts`:
```ts
import { z } from 'zod';

export const AgentdOperationNameSchema = z.enum([
  'runtime.run',
  'runtime.resume',
  'provider.chat',
  'provider.models',
  'workspace.list',
  'approval.respond',
]);
export type AgentdOperationName = z.infer<typeof AgentdOperationNameSchema>;

export const AgentdRequestSchema = z.object({
  requestId: z.string().min(1),
  operation: AgentdOperationNameSchema,
  payload: z.record(z.string(), z.unknown()),
});
export type AgentdRequest = z.infer<typeof AgentdRequestSchema>;

export const AgentdResponseSchema = z.object({
  requestId: z.string().min(1),
  ok: z.boolean(),
  result: z.record(z.string(), z.unknown()).optional(),
  error: z.object({ code: z.string(), message: z.string() }).optional(),
});
export type AgentdResponse = z.infer<typeof AgentdResponseSchema>;

export const AgentdEventSchema = z.object({
  runId: z.string().min(1),
  seq: z.number().int().min(0),
  type: z.string().min(1),
  data: z.record(z.string(), z.unknown()),
  createdAt: z.string().datetime(),
});
export type AgentdEvent = z.infer<typeof AgentdEventSchema>;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd repos/protocol && npx vitest run src/schemas/provider.test.ts src/schemas/agentd.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/schemas/provider.ts src/schemas/provider.test.ts src/schemas/agentd.ts src/schemas/agentd.test.ts
git commit -m "feat: add Provider and agentd operation schemas"
```

---

### Task 6: MemoryFact and ConversationSummary schemas

**Files:**
- Create: `repos/protocol/src/schemas/memory.ts`
- Create: `repos/protocol/src/schemas/memory.test.ts`

**Interfaces:**
- Produces: `MemoryFactSchema`/`MemoryFact`, `ConversationSummarySchema`/`ConversationSummary`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing test**

`repos/protocol/src/schemas/memory.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { ConversationSummarySchema, MemoryFactSchema } from './memory.js';

const now = '2026-01-01T00:00:00.000Z';

describe('MemoryFactSchema', () => {
  it('parses an inspectable, taggable fact', () => {
    const fact = MemoryFactSchema.parse({
      id: 'fact_1',
      agentId: 'agent_1',
      content: 'The user prefers terse responses.',
      source: 'conversation',
      tags: ['preferences'],
      createdAt: now,
      updatedAt: now,
    });
    expect(fact.tags).toEqual(['preferences']);
  });

  it('rejects empty content (nothing to inspect/dedupe against)', () => {
    expect(() =>
      MemoryFactSchema.parse({
        id: 'fact_2',
        agentId: 'agent_1',
        content: '',
        source: 'manual',
        createdAt: now,
        updatedAt: now,
      })
    ).toThrow();
  });
});

describe('ConversationSummarySchema', () => {
  it('parses a rolling summary anchored to a message', () => {
    const summary = ConversationSummarySchema.parse({
      conversationId: 'conversation_1',
      summary: 'Discussed launch plan; agreed on 2026-03-01 date.',
      upToMessageId: 'message_42',
      updatedAt: now,
    });
    expect(summary.upToMessageId).toBe('message_42');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd repos/protocol && npx vitest run src/schemas/memory.test.ts`
Expected: FAIL — module does not exist yet.

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/schemas/memory.ts`:
```ts
import { z } from 'zod';

export const MemoryFactSchema = z.object({
  id: z.string().min(1),
  agentId: z.string().min(1),
  content: z.string().min(1),
  source: z.enum(['conversation', 'manual', 'summary']),
  tags: z.array(z.string()).default([]),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
});
export type MemoryFact = z.infer<typeof MemoryFactSchema>;

export const ConversationSummarySchema = z.object({
  conversationId: z.string().min(1),
  summary: z.string().min(1),
  upToMessageId: z.string().min(1),
  updatedAt: z.string().datetime(),
});
export type ConversationSummary = z.infer<typeof ConversationSummarySchema>;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd repos/protocol && npx vitest run src/schemas/memory.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/schemas/memory.ts src/schemas/memory.test.ts
git commit -m "feat: add MemoryFact and ConversationSummary schemas"
```

---

### Task 7: WebSocket envelope, Approval schemas, barrel export, and package verification

**Files:**
- Create: `repos/protocol/src/schemas/websocket.ts`
- Create: `repos/protocol/src/schemas/websocket.test.ts`
- Create: `repos/protocol/src/schemas/approval.ts`
- Create: `repos/protocol/src/schemas/approval.test.ts`
- Modify: `repos/protocol/src/index.ts`
- Create: `repos/protocol/src/index.test.ts`

**Interfaces:**
- Produces: `WsServerEventSchema`/`WsServerEvent` (the envelope every WebSocket push
  from the server-foundations plan's `ConnectionHub` uses: `seq`, `topic`, `type`,
  `ts`, `payload`), `WsResumeRequestSchema`/`WsResumeRequest`.
  `ApprovalStatusSchema`/`ApprovalStatus`, `ApprovalRequestSchema`/`ApprovalRequest`,
  `ApprovalDecisionSchema`/`ApprovalDecision`. A fully populated `src/index.ts` barrel
  that re-exports every schema module — this is the only file server/sdk import from.
- Consumes: nothing new; this task also serves as final integration/verification for
  the whole package.

- [ ] **Step 1: Write the failing tests**

`repos/protocol/src/schemas/websocket.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { WsResumeRequestSchema, WsServerEventSchema } from './websocket.js';

describe('WsServerEventSchema', () => {
  it('parses a server-pushed event envelope', () => {
    const event = WsServerEventSchema.parse({
      seq: 42,
      topic: 'conversation:conversation_1',
      type: 'message.created',
      ts: '2026-01-01T00:00:00.000Z',
      payload: { id: 'message_1' },
    });
    expect(event.seq).toBe(42);
  });

  it('rejects seq below 1 (event_log is 1-indexed)', () => {
    expect(() =>
      WsServerEventSchema.parse({
        seq: 0,
        topic: 'conversation:conversation_1',
        type: 'message.created',
        ts: '2026-01-01T00:00:00.000Z',
        payload: {},
      })
    ).toThrow();
  });
});

describe('WsResumeRequestSchema', () => {
  it('parses a resume request with sinceSeq 0 for a brand-new client', () => {
    const resume = WsResumeRequestSchema.parse({ op: 'resume', sinceSeq: 0 });
    expect(resume.sinceSeq).toBe(0);
  });
});
```

`repos/protocol/src/schemas/approval.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { ApprovalDecisionSchema, ApprovalRequestSchema } from './approval.js';

const now = '2026-01-01T00:00:00.000Z';

describe('ApprovalRequestSchema', () => {
  it('parses a pending approval request', () => {
    const request = ApprovalRequestSchema.parse({
      id: 'approval_1',
      runId: 'run_1',
      agentId: 'agent_1',
      action: 'send_email',
      details: { to: 'user@example.com' },
      status: 'pending',
      createdAt: now,
      resolvedAt: null,
    });
    expect(request.status).toBe('pending');
  });
});

describe('ApprovalDecisionSchema', () => {
  it('parses an approve decision without a reason', () => {
    const decision = ApprovalDecisionSchema.parse({ approvalId: 'approval_1', decision: 'approve' });
    expect(decision.decision).toBe('approve');
  });
});
```

`repos/protocol/src/index.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import * as protocol from './index.js';

describe('protocol barrel export', () => {
  it('exposes every domain schema from a single entry point', () => {
    expect(protocol.PROTOCOL_VERSION).toBeDefined();
    expect(protocol.AgentSchema).toBeDefined();
    expect(protocol.RuntimeBindingSchema).toBeDefined();
    expect(protocol.RuntimeSessionSchema).toBeDefined();
    expect(protocol.ConversationSchema).toBeDefined();
    expect(protocol.MessageSchema).toBeDefined();
    expect(protocol.ProviderKindSchema).toBeDefined();
    expect(protocol.AgentdRequestSchema).toBeDefined();
    expect(protocol.MemoryFactSchema).toBeDefined();
    expect(protocol.WsServerEventSchema).toBeDefined();
    expect(protocol.ApprovalRequestSchema).toBeDefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd repos/protocol && npx vitest run src/schemas/websocket.test.ts src/schemas/approval.test.ts src/index.test.ts`
Expected: FAIL — `./websocket.js`/`./approval.js` don't exist, and `index.ts` doesn't
export any of the asserted names yet.

- [ ] **Step 3: Write minimal implementation**

`repos/protocol/src/schemas/websocket.ts`:
```ts
import { z } from 'zod';

export const WsServerEventSchema = z.object({
  seq: z.number().int().min(1),
  topic: z.string().min(1),
  type: z.string().min(1),
  ts: z.string().datetime(),
  payload: z.unknown(),
});
export type WsServerEvent = z.infer<typeof WsServerEventSchema>;

export const WsResumeRequestSchema = z.object({
  op: z.literal('resume'),
  sinceSeq: z.number().int().min(0),
});
export type WsResumeRequest = z.infer<typeof WsResumeRequestSchema>;
```

`repos/protocol/src/schemas/approval.ts`:
```ts
import { z } from 'zod';

export const ApprovalStatusSchema = z.enum(['pending', 'approved', 'denied', 'expired']);
export type ApprovalStatus = z.infer<typeof ApprovalStatusSchema>;

export const ApprovalRequestSchema = z.object({
  id: z.string().min(1),
  runId: z.string().min(1),
  agentId: z.string().min(1),
  action: z.string().min(1),
  details: z.record(z.string(), z.unknown()),
  status: ApprovalStatusSchema,
  createdAt: z.string().datetime(),
  resolvedAt: z.string().datetime().nullable(),
});
export type ApprovalRequest = z.infer<typeof ApprovalRequestSchema>;

export const ApprovalDecisionSchema = z.object({
  approvalId: z.string().min(1),
  decision: z.enum(['approve', 'deny']),
  reason: z.string().optional(),
});
export type ApprovalDecision = z.infer<typeof ApprovalDecisionSchema>;
```

`repos/protocol/src/index.ts`:
```ts
export * from './version.js';
export * from './schemas/agent.js';
export * from './schemas/runtime.js';
export * from './schemas/conversation.js';
export * from './schemas/message.js';
export * from './schemas/provider.js';
export * from './schemas/agentd.js';
export * from './schemas/memory.js';
export * from './schemas/websocket.js';
export * from './schemas/approval.js';
```

- [ ] **Step 4: Run the full test suite and the build to verify everything passes**

Run: `cd repos/protocol && npm test && npm run build`
Expected: all test files pass (9 files: version, agent, runtime, conversation,
message, provider, agentd, memory, websocket, approval, index — 10 total), and
`npm run build` emits `dist/index.js`/`dist/index.d.ts` with no TypeScript errors.

- [ ] **Step 5: Commit**

```bash
cd repos/protocol
git add src/schemas/websocket.ts src/schemas/websocket.test.ts src/schemas/approval.ts src/schemas/approval.test.ts src/index.ts src/index.test.ts
git commit -m "feat: add WebSocket/Approval schemas and complete protocol barrel export"
```

---

## Handoff to server-foundations

Once this plan is complete, `repos/server` (next plan) depends on this package with:

```json
"@opencrew/protocol": "file:../protocol"
```

which resolves to `repos/protocol` on disk relative to `repos/server`. No publish step
is required for v0.1 — `npm install` copies/symlinks the local package directly.
