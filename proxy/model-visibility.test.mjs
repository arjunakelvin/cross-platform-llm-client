// Regression test untuk visibilitas model + aturan tagihan kredit.
//
// Bug yang pernah lolos:
// 1. Model yang dinonaktifkan admin tetap muncul di aplikasi dan masih bisa
//    dipanggil lewat gateway kalau id-nya sudah dipegang client.
// 2. Model PRO/VIP berharga diam-diam turun ke mode token saat kredit habis,
//    sehingga log pemakaian menunjukkan token untuk model berbayar.
//
// Jalankan: node --test proxy/model-visibility.test.mjs

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

function seed(store, overrides = {}) {
  store.set('mgr_servers', JSON.stringify([
    { id: 'server-1', name: 'VPS 1', enabled: true },
  ]));
  store.set('server_models', JSON.stringify([{
    modelId: MODEL_ID,
    backendModelId: 'qwen.gguf',
    name: 'Qwen 3B',
    serverId: 'server-1',
    tierAccess: ['pro', 'vip'],
    pricing: { inputPerReq: 0.0126 },
    active: true,
    ...overrides,
  }]));
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'user',
    tier: 'pro',
    status: 'active',
    tokenBalance: 100000,
    tokenUsed: 0,
    creditBalance: 1,
    creditUsed: 0,
  }));
  store.set(`session:${SESSION}`, 'u1');
}

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

function chat(env, model = MODEL_ID) {
  return call(env, '/api/gateway/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SESSION}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model,
      messages: [{ role: 'user', content: 'halo' }],
    }),
  });
}

test('model yang disembunyikan tidak muncul di config aplikasi', async () => {
  const { store, env } = makeEnv();
  seed(store, { enabled: false });

  const res = await call(env, '/api/auth/config');
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.equal(body.models.length, 0);
});

test('model yang disembunyikan tidak muncul di /api/gateway/models', async () => {
  const { store, env } = makeEnv();
  seed(store, { enabled: false });

  const res = await call(env, '/api/gateway/models', {
    headers: { Authorization: `Bearer ${SESSION}` },
  });
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.equal(body.models.length, 0);
});

test('gateway menolak model yang disembunyikan walaupun id diketahui', async () => {
  const { store, env } = makeEnv();
  seed(store, { enabled: false });

  const res = await chat(env);
  const body = await res.json();

  assert.equal(res.status, 403);
  assert.match(body.error, /dinonaktifkan admin/i);
});

test('model PRO berharga memakai kredit; saldo 0 ditolak 402 (bukan token)', async () => {
  const { store, env } = makeEnv();
  seed(store);
  const account = JSON.parse(store.get('account:u1'));
  account.creditBalance = 0;
  store.set('account:u1', JSON.stringify(account));

  const res = await chat(env);
  const body = await res.json();

  assert.equal(res.status, 402);
  assert.equal(body.billing, 'credit');
  assert.equal(body.balance, 0);
  // Kuota token tidak boleh terpakai sebagai pengganti.
  assert.equal(JSON.parse(store.get('account:u1')).tokenUsed, 0);
});

test('kredit kurang dari harga per request → 402, bukan potong token', async () => {
  const { store, env } = makeEnv();
  seed(store);
  const account = JSON.parse(store.get('account:u1'));
  account.creditBalance = 0.01; // harga per request 0.0126
  store.set('account:u1', JSON.stringify(account));

  const res = await chat(env);
  const body = await res.json();

  assert.equal(res.status, 402);
  assert.equal(body.billing, 'credit');
  assert.equal(body.required, 0.0126);
});

test('admin POST bisa menyembunyikan lalu menampilkan model lagi', async () => {
  const { store, env } = makeEnv();
  seed(store);

  const hide = await call(env, '/api/admin/server-models', {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ modelId: MODEL_ID, enabled: false }),
  });
  assert.equal(hide.status, 200);
  let config = await (await call(env, '/api/auth/config')).json();
  assert.equal(config.models.length, 0);
  assert.equal(JSON.parse(store.get('server_models'))[0].enabled, false);

  const show = await call(env, '/api/admin/server-models', {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ modelId: MODEL_ID, enabled: true }),
  });
  assert.equal(show.status, 200);
  config = await (await call(env, '/api/auth/config')).json();
  assert.equal(config.models.length, 1);
  assert.equal(JSON.parse(store.get('server_models'))[0].enabled, true);
});