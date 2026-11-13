// Regression test untuk id publik model gateway.
//
// Bug yang pernah lolos:
// 1. Model yang tier-nya diubah ke PRO/VIP di dashboard tetap punya id
//    `…:free` karena handleServerModels() menyimpan modelId apa adanya.
// 2. gatewayPublicIdFor() mempertahankan id lama, jadi /v1/models juga
//    masih menampilkan `:free` sampai deteksi model dijalankan ulang.
//
// Jalankan: node --test proxy/model-id.test.mjs

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

const STALE_ID =
  'qwen-3b-albriterated:qwen2.5-coder-3b-instruct-abliterated:free';
const FIXED_ID =
  'qwen-3b-albriterated:qwen2.5-coder-3b-instruct-abliterated:pro';

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

function seedModels(store, overrides = {}) {
  const models = [{
    modelId: STALE_ID,
    backendModelId: 'Qwen2.5-Coder-3B-Instruct-abliterated-Q4_K_M.gguf',
    name: 'Qwen2.5 Coder 3B Instruct Abliterated',
    serverId: 'server-1',
    tierAccess: ['pro', 'vip'],
    pricing: { inputPerReq: 0.0065, outputPerReq: 0.0061 },
    ...overrides,
  }];
  store.set('server_models', JSON.stringify(models));
  store.set('mgr_servers', JSON.stringify([
    { id: 'server-1', name: 'AI-Qwen 3B' },
  ]));
  return models;
}

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

test('GET admin memigrasi id :free ke tier yang disimpan', async () => {
  const { store, env } = makeEnv();
  seedModels(store);

  const res = await call(env, '/api/admin/server-models', {
    headers: { 'X-Admin-Key': ADMIN_KEY },
  });
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.equal(body.models.length, 1);
  assert.equal(body.models[0].modelId, FIXED_ID);
  assert.equal(body.models[0].publicId, FIXED_ID);
  // Perubahan ikut disimpan ke KV, bukan cuma di response.
  assert.equal(JSON.parse(store.get('server_models'))[0].modelId, FIXED_ID);
});

test('/api/auth/config mengirim id publik dengan tier terbaru', async () => {
  const { store, env } = makeEnv();
  seedModels(store);

  const res = await call(env, '/api/auth/config');
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.equal(body.models[0].modelId, FIXED_ID);
  assert.deepEqual(body.models[0].tierAccess, ['pro', 'vip']);
});

test('POST admin tidak membuat duplikat saat id lama masih :free', async () => {
  const { store, env } = makeEnv();
  seedModels(store);

  // Dashboard mengirim id yang sudah di-retag + tier baru (VIP).
  const res = await call(env, '/api/admin/server-models', {
    method: 'POST',
    headers: {
      'X-Admin-Key': ADMIN_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      modelId: FIXED_ID,
      backendModelId: 'Qwen2.5-Coder-3B-Instruct-abliterated-Q4_K_M.gguf',
      name: 'Qwen2.5 Coder 3B Instruct Abliterated',
      serverId: 'server-1',
      tierAccess: ['vip'],
      pricing: { inputPerReq: 0.0065, outputPerReq: 0.0065 },
    }),
  });
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.equal(
    body.model.modelId,
    'qwen-3b-albriterated:qwen2.5-coder-3b-instruct-abliterated:vip',
  );
  const stored = JSON.parse(store.get('server_models'));
  assert.equal(stored.length, 1, 'tidak boleh ada entri duplikat');
  assert.equal(
    stored[0].modelId,
    'qwen-3b-albriterated:qwen2.5-coder-3b-instruct-abliterated:vip',
  );
  assert.equal(stored[0].pricing.outputPerReq, 0.0065);
});
test('DELETE dengan id :free lama tetap menghapus entri yang sudah :pro', async () => {
  const { store, env } = makeEnv();
  seedModels(store);
  // KV sengaja masih menyimpan id :free (belum sempat GET admin).
  const res = await call(
    env,
    '/api/admin/server-models/' + encodeURIComponent(STALE_ID),
    { method: 'DELETE', headers: { 'X-Admin-Key': ADMIN_KEY } },
  );
  assert.equal(res.status, 200);
  assert.equal(JSON.parse(store.get('server_models')).length, 0);
});
