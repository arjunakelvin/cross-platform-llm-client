// Regression test untuk system prompt global + harga /req input/output.
//
// Bug yang pernah lolos:
// 1. System prompt hanya bisa diubah dari Settings aplikasi, padahal admin
//    seharusnya mengatur satu prompt global lewat dashboard.
// 2. Harga /req hanya punya satu field input; harga output dipaksa 0 sehingga
//    total tagihan per panggilan salah.
//
// Jalankan: node --test proxy/admin-config.test.mjs

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
const SESSION = 'session-token-1';
const MODEL_ID = 'qwen-3b:qwen2.5-coder-3b:pro';

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

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

function adminPatch(env, body) {
  return call(env, '/api/admin/config', {
    method: 'PATCH',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function getConfig(env, path) {
  const res = await call(env, path, {
    headers: path.startsWith('/api/admin/')
      ? { 'X-Admin-Key': ADMIN_KEY }
      : {},
  });
  return { res, body: await res.json() };
}

test('system prompt kosong secara default', async () => {
  const { env } = makeEnv();

  const admin = await getConfig(env, '/api/admin/config');
  assert.equal(admin.res.status, 200);
  assert.equal(admin.body.systemPrompt, '');

  const pub = await getConfig(env, '/api/auth/config');
  assert.equal(pub.res.status, 200);
  assert.equal(pub.body.systemPrompt, '');
});

test('admin menyimpan system prompt dan aplikasi menerimanya', async () => {
  const { store, env } = makeEnv();
  const prompt = '  Kamu adalah asisten PiercingBlow.  ';

  const patch = await adminPatch(env, { systemPrompt: prompt });
  assert.equal(patch.status, 200);

  const admin = await getConfig(env, '/api/admin/config');
  assert.equal(admin.body.systemPrompt, 'Kamu adalah asisten PiercingBlow.');
  assert.equal(
    JSON.parse(store.get('config')).systemPrompt,
    'Kamu adalah asisten PiercingBlow.',
  );

  const pub = await getConfig(env, '/api/auth/config');
  assert.equal(pub.body.systemPrompt, 'Kamu adalah asisten PiercingBlow.');
});

test('system prompt kosong menghapus prompt global (fallback default)', async () => {
  const { env } = makeEnv();

  await adminPatch(env, { systemPrompt: 'Prompt sementara' });
  const saved = await getConfig(env, '/api/admin/config');
  assert.equal(saved.body.systemPrompt, 'Prompt sementara');

  await adminPatch(env, { systemPrompt: '   ' });
  const cleared = await getConfig(env, '/api/admin/config');
  assert.equal(cleared.body.systemPrompt, '');

  const pub = await getConfig(env, '/api/auth/config');
  assert.equal(pub.body.systemPrompt, '');
});

test('system prompt dibatasi panjangnya', async () => {
  const { env } = makeEnv();

  await adminPatch(env, { systemPrompt: 'x'.repeat(20000) });
  const admin = await getConfig(env, '/api/admin/config');
  assert.equal(admin.body.systemPrompt.length, 12000);
});

test('harga /req menjumlahkan input + output saat cek saldo', async () => {
  const { store, env } = makeEnv();
  store.set('mgr_servers', JSON.stringify([
    { id: 'server-1', name: 'VPS 1', enabled: true },
  ]));
  store.set('server_models', JSON.stringify([{
    modelId: MODEL_ID,
    backendModelId: 'qwen.gguf',
    name: 'Qwen 3B',
    serverId: 'server-1',
    tierAccess: ['pro', 'vip'],
    // Input $0.01 + output $0.02 per request = $0.03 total.
    pricing: { inputPerReq: 0.01, outputPerReq: 0.02 },
    active: true,
  }]));
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'user',
    tier: 'pro',
    status: 'active',
    tokenBalance: 100000,
    tokenUsed: 0,
    // Cukup untuk input saja, tapi tidak cukup untuk input + output.
    creditBalance: 0.025,
    creditUsed: 0,
  }));
  store.set(`session:${SESSION}`, 'u1');

  const res = await call(env, '/api/gateway/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SESSION}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: MODEL_ID,
      messages: [{ role: 'user', content: 'halo' }],
    }),
  });
  const body = await res.json();

  assert.equal(res.status, 402);
  assert.equal(body.billing, 'credit');
  assert.equal(body.required, 0.03);
});

test('gateway memblokir prompt yang melebihi context (413, bukan error backend)', async () => {
  const { store, env } = makeEnv();

  store.set('mgr_servers', JSON.stringify([
    { id: 'server-1', name: 'VPS 1', enabled: true, baseUrl: 'http://10.0.0.9:8080' },
  ]));
  store.set('server_models', JSON.stringify([{
    modelId: MODEL_ID,
    backendModelId: 'qwen.gguf',
    name: 'Qwen 3B',
    serverId: 'server-1',
    tierAccess: ['free'],
    pricing: {},
    contextSize: 4096,
    maxOutput: 2048,
    enabled: true,
    active: true,
  }]));
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'user',
    tier: 'free',
    status: 'active',
    tokenBalance: 100000,
    tokenUsed: 0,
    creditBalance: 100,
    creditUsed: 0,
  }));
  store.set(`session:${SESSION}`, 'u1');

  const longPrompt = 'x'.repeat(60_000);
  const res = await call(env, '/api/gateway/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SESSION}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: MODEL_ID,
      messages: [{ role: 'user', content: longPrompt }],
    }),
  });
  const body = await res.json();

  assert.equal(res.status, 413);
  assert.ok(String(body.error).toLowerCase().includes('terlalu panjang'));
  assert.equal(Number(body.promptTokens), 15010);
});

test('cache-stats mengembalikan statistik per model (hit/miss/pemakaian)', async () => {
  const { env } = makeEnv();

  const res = await call(env, '/api/auth/cache-stats');
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(body.models));
});

test('admin model-stats mengembalikan ringkasan per model', async () => {
  const { store, env } = makeEnv();
  store.set('server_models', JSON.stringify([{
    modelId: MODEL_ID,
    backendModelId: 'qwen.gguf',
    name: 'Qwen 3B',
    serverId: 'server-1',
    tierAccess: ['free'],
    pricing: {},
    contextSize: 4096,
    maxOutput: 2048,
    enabled: true,
    active: true,
  }]));

  const res = await call(env, '/api/admin/model-stats', {
    headers: { 'X-Admin-Key': ADMIN_KEY },
  });
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(body.models));
  assert.equal(body.models.length, 1);
  assert.equal(body.models[0].modelId, MODEL_ID);
});