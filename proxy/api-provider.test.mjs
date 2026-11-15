// Test provider API eksternal (Cloudflare Workers AI / OpenAI-compatible).
//
// Fitur yang diuji:
// 1. Admin bisa menambah provider hanya dengan base URL + API key.
// 2. Provider tampil di config aplikasi sebagai `api:<id>` tanpa API key.
// 3. Gateway memproksi request dengan Authorization Bearer provider.
// 4. Respons Cloudflare `{result:{response}}` dikonversi ke format OpenAI
//    (non-stream & stream SSE) supaya aplikasi tidak perlu diubah.
// 5. Batas request harian per akun (limit provider / limit global).
// 6. Prompt yang melebihi context provider ditolak 413.
//
// Jalankan: node --test proxy/api-provider.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(
  new URL('./cloudflare-worker.js', import.meta.url), 'utf8');
const moduleUrl =
  'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
const { default: worker } = await import(moduleUrl);

const ORIGIN = 'http://localhost';
const ADMIN_KEY = 'test-admin';
const SESSION = 'session-provider-1';
const PROVIDER_ID = 'cf-kimi';
const MODEL_ID = `api:${PROVIDER_ID}`;
const CF_URL =
  'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run/@cf/moonshotai/kimi-k2.7-code';

function makeEnv() {
  const store = new Map();
  const kv = {
    async get(key) {
      return store.has(key) ? store.get(key) : null;
    },
    async put(key, value) {
      store.set(key, String(value));
    },
    async delete(key) {
      store.delete(key);
    },
    async list({ prefix } = {}) {
      return {
        keys: [...store.keys()]
          .filter((key) => !prefix || key.startsWith(prefix))
          .map((name) => ({ name })),
        list_complete: true,
        cursor: '',
      };
    },
  };
  return { store, env: { PB_KV: kv, ADMIN_KEY } };
}

function seedAccount(store) {
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'user',
    tier: 'free',
    status: 'active',
    tokenBalance: 100000,
    tokenUsed: 0,
    creditBalance: 1,
    creditUsed: 0,
  }));
  store.set(`session:${SESSION}`, 'u1');
}

function seedProvider(store, overrides = {}) {
  store.set('api_providers', JSON.stringify([{
    id: PROVIDER_ID,
    name: 'Kimi K2.7 (Cloudflare)',
    baseUrl: CF_URL,
    apiKey: 'cfut_secret',
    model: '@cf/moonshotai/kimi-k2.7-code',
    format: 'auto',
    contextSize: 262144,
    maxOutput: 8192,
    dailyRequestLimit: 0,
    tierAccess: ['free', 'pro', 'vip'],
    pricing: {},
    enabled: true,
    ...overrides,
  }]));
}

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

function chat(env, body = {}) {
  return call(env, '/api/gateway/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SESSION}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: MODEL_ID,
      messages: [{ role: 'user', content: 'halo' }],
      ...body,
    }),
  });
}

function mockFetch(handler) {
  const original = globalThis.fetch;
  globalThis.fetch = handler;
  return () => { globalThis.fetch = original; };
}

test('admin bisa menambah provider; API key tidak pernah dibuka', async () => {
  const { store, env } = makeEnv();

  const res = await call(env, '/api/admin/api-providers', {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: 'Kimi K2.7',
      baseUrl: CF_URL,
      apiKey: 'cfut_secret',
      model: '@cf/moonshotai/kimi-k2.7-code',
      contextSize: 262144,
      maxOutput: 8192,
      dailyRequestLimit: 20,
    }),
  });
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.provider.apiKey, '');
  assert.equal(body.provider.hasApiKey, true);
  assert.equal(body.provider.dailyRequestLimit, 20);
  assert.equal(body.provider.id, 'kimi-k2-7');

  const saved = JSON.parse(store.get('api_providers'));
  assert.equal(saved.length, 1);
  assert.equal(saved[0].apiKey, 'cfut_secret');

  const list = await (await call(env, '/api/admin/api-providers', {
    headers: { 'X-Admin-Key': ADMIN_KEY },
  })).json();
  assert.equal(list.providers.length, 1);
  assert.equal(list.providers[0].apiKey, '');
});

test('config aplikasi memuat model provider tanpa API key', async () => {
  const { store, env } = makeEnv();
  seedProvider(store);

  const res = await call(env, '/api/auth/config');
  const body = await res.json();
  const model = body.models.find((m) => m.modelId === MODEL_ID);

  assert.equal(res.status, 200);
  assert.ok(model, 'model provider harus muncul di config');
  assert.equal(model.provider, 'external');
  assert.equal(model.contextSize, 262144);
  assert.equal(model.apiKey, undefined);
  assert.equal(JSON.stringify(model).includes('cfut_secret'), false);
});

test('gateway memproksi ke Cloudflare dan mengubah respons ke format OpenAI', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store);

  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      success: true,
      result: { response: 'Halo dari Kimi' },
      errors: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env);
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(body.choices[0].message.content, 'Halo dari Kimi');
    assert.ok(body.usage.completion_tokens > 0);
    // Upstream menerima Authorization Bearer API key provider.
    assert.equal(captured.url, CF_URL);
    assert.equal(captured.init.headers.get('Authorization'), 'Bearer cfut_secret');
    assert.equal(captured.init.headers.get('X-Secret-Key'), null);
    const sent = JSON.parse(captured.init.body);
    assert.equal(sent.model, '@cf/moonshotai/kimi-k2.7-code');
    assert.ok(sent.max_tokens > 0);
    assert.equal(sent.stream_options, undefined);
  } finally {
    restore();
  }
});

test('stream Cloudflare dikonversi menjadi delta OpenAI + usage', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store);

  const restore = mockFetch(async () => {
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode('data: {"response":"Ha"}\n\n'));
        controller.enqueue(encoder.encode('data: {"response":"lo"}\n\n'));
        controller.enqueue(encoder.encode('data: [DONE]\n\n'));
        controller.close();
      },
    });
    return new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    });
  });
  try {
    const res = await chat(env, { stream: true });
    const text = await res.text();
    assert.equal(res.status, 200);
    assert.match(text, /"delta":\{"content":"Ha"\}/);
    assert.match(text, /"delta":\{"content":"lo"\}/);
    assert.match(text, /data: \[DONE\]/);
    assert.match(text, /piercingblow_usage/);
    // Event usage harus datang setelah [DONE] (urutan yang dipakai app).
    assert.ok(text.indexOf('[DONE]') < text.indexOf('piercingblow_usage'));
  } finally {
    restore();
  }
});

test('provider OpenAI-compatible: URL dan respons diteruskan', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store, {
    baseUrl: 'https://api.example.com/v1',
    model: 'contoh-model',
    apiKey: 'sk-test',
  });

  let capturedUrl = '';
  const restore = mockFetch(async (url) => {
    capturedUrl = String(url);
    return new Response(JSON.stringify({
      id: 'chatcmpl-1',
      object: 'chat.completion',
      choices: [{
        index: 0,
        message: { role: 'assistant', content: 'OK' },
        finish_reason: 'stop',
      }],
      usage: { prompt_tokens: 3, completion_tokens: 1, total_tokens: 4 },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env);
    const body = await res.json();
    assert.equal(capturedUrl, 'https://api.example.com/v1/chat/completions');
    assert.equal(body.choices[0].message.content, 'OK');
  } finally {
    restore();
  }
});

test('batas request harian per akun ditegakkan (429)', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store, { dailyRequestLimit: 1 });

  let upstreamCalls = 0;
  const restore = mockFetch(async () => {
    upstreamCalls++;
    return new Response(JSON.stringify({
      success: true,
      result: { response: 'ok' },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const first = await chat(env);
    assert.equal(first.status, 200);

    const second = await chat(env);
    const body = await second.json();
    assert.equal(second.status, 429);
    assert.equal(body.limit, 1);
    assert.equal(body.used, 1);
    assert.match(body.error, /request\/hari/i);
    // Request kedua tidak boleh menyentuh provider.
    assert.equal(upstreamCalls, 1);
  } finally {
    restore();
  }
});

test('prompt melebihi context provider ditolak 413', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store, { contextSize: 100, maxOutput: 50 });

  const res = await chat(env, {
    messages: [{ role: 'user', content: 'x'.repeat(400) }],
  });
  const body = await res.json();
  assert.equal(res.status, 413);
  assert.match(body.error, /context/i);
  assert.ok(body.promptTokens > 100);
});

test('tes koneksi provider mengembalikan status upstream', async () => {
  const { store, env } = makeEnv();
  seedProvider(store);
  const restore = mockFetch(async () => new Response(
    JSON.stringify({ success: true, result: { response: 'pong' } }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  ));
  try {
    const res = await call(env, '/api/admin/api-providers/test', {
      method: 'POST',
      headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: PROVIDER_ID }),
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(body.ok, true);
    assert.equal(body.status, 200);
  } finally {
    restore();
  }
});

test('banyak model per provider: id unik, harga & context per model', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  store.set('api_providers', JSON.stringify([{
    id: 'cf',
    name: 'Cloudflare Workers AI',
    baseUrl: 'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run',
    apiKey: 'cfut_secret',
    format: 'auto',
    tierAccess: ['free', 'pro', 'vip'],
    enabled: true,
    models: [
      {
        key: 'kimi',
        modelId: '@cf/moonshotai/kimi-k2.7-code',
        name: 'Kimi K2.7 Code',
        contextSize: 131072,
        maxOutput: 4096,
        dailyRequestLimit: 5,
        pricing: { inputPer1M: 2, outputPer1M: 4 },
        enabled: true,
      },
      {
        key: 'llama',
        modelId: '@cf/meta/llama-3.1-8b-instruct',
        name: 'Llama 3.1 8B',
        contextSize: 8192,
        maxOutput: 1024,
        pricing: { inputPerReq: 0.01, outputPerReq: 0.02 },
        enabled: false,
      },
    ],
  }]));

  const config = await (await call(env, '/api/auth/config')).json();
  const kimi = config.models.find((m) => m.modelId === 'api:cf:kimi');
  const llama = config.models.find((m) => m.modelId === 'api:cf:llama');

  assert.ok(kimi, 'model pertama memakai id api:<provider>:<key>');
  assert.equal(kimi.name, 'Kimi K2.7 Code');
  // Nama provider tidak boleh tampil ke user.
  assert.equal(kimi.serverName, 'AI API');
  assert.equal(JSON.stringify(kimi).includes('Cloudflare Workers AI'), false);
  assert.equal(kimi.contextSize, 131072);
  assert.equal(kimi.dailyRequestLimit, 5);
  assert.equal(llama, undefined, 'model yang dimatikan tidak tampil');

  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      success: true,
      result: { response: 'ok' },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env, { model: 'api:cf:kimi' });
    assert.equal(res.status, 200);
    // Base URL /ai/run + model ID ditempel otomatis.
    assert.equal(
      captured.url,
      'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run/@cf/moonshotai/kimi-k2.7-code',
    );
    assert.equal(JSON.parse(captured.init.body).model,
      '@cf/moonshotai/kimi-k2.7-code');

    const blocked = await chat(env, { model: 'api:cf:llama' });
    assert.equal(blocked.status, 403, 'model nonaktif ditolak gateway');
  } finally {
    restore();
  }
});

test('harga per model provider dipakai untuk tagihan kredit', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  store.set('api_providers', JSON.stringify([{
    id: 'paid',
    name: 'Paid Provider',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    format: 'openai',
    tierAccess: ['pro'],
    enabled: true,
    models: [{
      key: 'm',
      modelId: 'paid-model',
      name: 'Paid Model',
      contextSize: 4096,
      maxOutput: 512,
      pricing: { inputPerReq: 0.5, outputPerReq: 0.5 },
      enabled: true,
    }],
  }]));
  // Akun pro dengan kredit pas untuk satu request.
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'pro',
    tier: 'pro',
    status: 'active',
    tokenBalance: 1000,
    tokenUsed: 0,
    creditBalance: 1,
    creditUsed: 0,
  }));
  const restore = mockFetch(async () => new Response(JSON.stringify({
    success: true,
    result: { response: 'halo' },
  }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
  try {
    // Harga per request 1.0 > saldo 1? Saldo 1 cukup (tidak boleh minus),
    // lalu saldo turun.
    const first = await chat(env, { model: 'api:paid:m' });
    assert.equal(first.status, 200);
    const account = JSON.parse(store.get('account:u1'));
    assert.ok(Number(account.creditBalance) < 1, 'kredit terpotong');
    const second = await chat(env, { model: 'api:paid:m' });
    assert.equal(second.status, 402, 'saldo habis ditolak');
  } finally {
    restore();
  }
});

// -- Cloudflare REST universal + Anthropic -------------------------------
// Endpoint baru Cloudflare: POST /ai/run dengan body { model, input }.
// Model pihak ketiga memakai nama `openai/...`, `anthropic/...`, dst.

function seedCloudProvider(store, provider) {
  store.set('api_providers', JSON.stringify([{
    id: 'cf',
    name: 'Cloudflare',
    apiKey: 'cfut_secret',
    format: 'auto',
    tierAccess: ['free', 'pro', 'vip'],
    enabled: true,
    ...provider,
  }]));
}

test('Cloudflare /ai/run: model pihak ketiga memakai envelope model+input', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedCloudProvider(store, {
    baseUrl: 'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run',
    gatewayId: 'default',
    models: [{
      key: 'gpt41',
      modelId: 'openai/gpt-4.1',
      name: 'GPT 4.1',
      contextSize: 128000,
      maxOutput: 1024,
      pricing: {},
      enabled: true,
    }],
  });

  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      success: true,
      result: {
        id: 'chatcmpl-x',
        choices: [{
          index: 0,
          message: { role: 'assistant', content: 'Halo GPT' },
          finish_reason: 'stop',
        }],
        usage: { prompt_tokens: 11, completion_tokens: 3 },
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env, { model: 'api:cf:gpt41' });
    const body = await res.json();
    assert.equal(res.status, 200);
    // Base URL /ai/run dipanggil apa adanya (bukan ditambah nama model).
    assert.equal(captured.url,
      'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run');
    const sent = JSON.parse(captured.init.body);
    assert.equal(sent.model, 'openai/gpt-4.1');
    assert.equal(sent.messages, undefined, 'universal memakai input, bukan messages');
    assert.equal(sent.input.messages[0].content, 'halo');
    assert.ok(sent.input.max_tokens > 0);
    assert.equal(captured.init.headers.get('cf-aig-gateway-id'), 'default');
    // Respons { result: {...OpenAI...} } dirapikan ke chat.completion.
    assert.equal(body.choices[0].message.content, 'Halo GPT');
    assert.equal(body.usage.prompt_tokens, 11);
    assert.equal(body.usage.completion_tokens, 3);
  } finally {
    restore();
  }
});

test('Cloudflare universal: model @cf/ otomatis memakai gateway default', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedCloudProvider(store, {
    baseUrl: 'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run',
    format: 'cloudflare-universal',
    models: [{
      key: 'llama',
      modelId: '@cf/meta/llama-3.1-8b-instruct',
      name: 'Llama 3.1 8B',
      contextSize: 8192,
      maxOutput: 512,
      pricing: {},
      enabled: true,
    }],
  });

  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      success: true,
      result: { response: 'ok universal' },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env, { model: 'api:cf:llama' });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(captured.url,
      'https://api.cloudflare.com/client/v4/accounts/acc123/ai/run');
    assert.equal(captured.init.headers.get('cf-aig-gateway-id'), 'default');
    const sent = JSON.parse(captured.init.body);
    assert.equal(sent.model, '@cf/meta/llama-3.1-8b-instruct');
    assert.ok(Array.isArray(sent.input.messages));
    assert.equal(body.choices[0].message.content, 'ok universal');
  } finally {
    restore();
  }
});

test('Anthropic native: body, header, dan respons dikonversi ke OpenAI', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedCloudProvider(store, {
    id: 'claude',
    name: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    apiKey: 'sk-ant-secret',
    models: [{
      key: 'sonnet',
      modelId: 'claude-sonnet-4-20250514',
      name: 'Claude Sonnet 4',
      contextSize: 200000,
      maxOutput: 4096,
      pricing: {},
      enabled: true,
    }],
  });

  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      id: 'msg_1',
      type: 'message',
      role: 'assistant',
      content: [{ type: 'text', text: 'Halo Claude' }],
      usage: { input_tokens: 9, output_tokens: 4 },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env, {
      model: 'api:claude:sonnet',
      messages: [
        { role: 'system', content: 'Kamu asisten ringkas.' },
        { role: 'user', content: 'halo' },
      ],
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(captured.url, 'https://api.anthropic.com/v1/messages');
    assert.equal(captured.init.headers.get('x-api-key'), 'sk-ant-secret');
    assert.equal(captured.init.headers.get('anthropic-version'), '2023-06-01');
    assert.equal(captured.init.headers.get('Authorization'), null);
    const sent = JSON.parse(captured.init.body);
    assert.equal(sent.model, 'claude-sonnet-4-20250514');
    assert.equal(sent.system, 'Kamu asisten ringkas.');
    assert.equal(sent.messages.length, 1);
    assert.ok(sent.max_tokens > 0);
    assert.equal(body.choices[0].message.content, 'Halo Claude');
    assert.equal(body.usage.prompt_tokens, 9);
    assert.equal(body.usage.completion_tokens, 4);
  } finally {
    restore();
  }
});

test('Cloudflare /ai/v1 + model anthropic memakai Bearer dan /ai/v1/messages', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedCloudProvider(store, {
    baseUrl: 'https://api.cloudflare.com/client/v4/accounts/acc123/ai/v1',
    models: [{
      key: 'claude',
      modelId: 'anthropic/claude-sonnet-4',
      name: 'Claude Sonnet 4',
      contextSize: 200000,
      maxOutput: 2048,
      pricing: {},
      enabled: true,
    }],
  });
  let captured = null;
  const restore = mockFetch(async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({
      content: [{ type: 'text', text: 'via cloudflare' }],
      usage: { input_tokens: 5, output_tokens: 2 },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  });
  try {
    const res = await chat(env, { model: 'api:cf:claude' });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(captured.url,
      'https://api.cloudflare.com/client/v4/accounts/acc123/ai/v1/messages');
    assert.equal(captured.init.headers.get('Authorization'), 'Bearer cfut_secret');
    assert.equal(captured.init.headers.get('x-api-key'), null);
    assert.equal(body.choices[0].message.content, 'via cloudflare');
  } finally {
    restore();
  }
});

test('stream Anthropic dikonversi menjadi delta OpenAI + usage', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedCloudProvider(store, {
    id: 'claude',
    baseUrl: 'https://api.anthropic.com/v1',
    apiKey: 'sk-ant-secret',
    models: [{
      key: 'sonnet',
      modelId: 'claude-sonnet-4-20250514',
      name: 'Claude Sonnet 4',
      contextSize: 200000,
      maxOutput: 2048,
      pricing: {},
      enabled: true,
    }],
  });

  const events = [
    'data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ha"}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}',
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}',
    'data: [DONE]',
  ];
  const restore = mockFetch(async () => {
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) {
        for (const line of events) {
          controller.enqueue(encoder.encode(line + '\n\n'));
        }
        controller.close();
      },
    });
    return new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    });
  });
  try {
    const res = await chat(env, { model: 'api:claude:sonnet', stream: true });
    const text = await res.text();
    assert.equal(res.status, 200);
    assert.match(text, /"delta":\{"content":"Ha"\}/);
    assert.match(text, /"delta":\{"content":"lo"\}/);
    assert.match(text, /data: \[DONE\]/);
    assert.match(text, /"prompt_tokens":12/);
    assert.match(text, /"completion_tokens":5/);
    assert.ok(text.indexOf('[DONE]') < text.indexOf('piercingblow_usage'));
  } finally {
    restore();
  }
});

test('stream Cloudflare yang dibungkus result tetap jadi delta OpenAI', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedProvider(store);

  const restore = mockFetch(async () => {
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) {
        // Workers AI baru membungkus chunk OpenAI di `result`.
        controller.enqueue(encoder.encode(
          'data: {"result":{"choices":[{"index":0,"delta":{"content":"Ha"}}]}}\n\n'));
        controller.enqueue(encoder.encode(
          'data: {"result":{"choices":[{"index":0,"delta":{"content":"lo"}}]}}\n\n'));
        controller.enqueue(encoder.encode('data: [DONE]\n\n'));
        controller.close();
      },
    });
    return new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    });
  });
  try {
    const res = await chat(env, { stream: true });
    const text = await res.text();
    assert.equal(res.status, 200);
    assert.match(text, /"delta":\{"content":"Ha"\}/);
    assert.match(text, /"delta":\{"content":"lo"\}/);
    assert.doesNotMatch(text, /"result"/);
    assert.match(text, /data: \[DONE\]/);
  } finally {
    restore();
  }
});
