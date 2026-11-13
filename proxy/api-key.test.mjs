// Regression test untuk endpoint API key di Cloudflare Worker.
//
// Bug yang pernah lolos: handleApiKey() memakai `account` padahal variabel
// itu tidak pernah didefinisikan (harusnya `session.account`), sehingga
// POST /api/auth/api-key selalu 500 "Worker error: ReferenceError".
//
// Jalankan: node --test proxy/api-key.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(
  new URL('./cloudflare-worker.js', import.meta.url), 'utf8');
const moduleUrl =
  'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
const { default: worker } = await import(moduleUrl);

const ORIGIN = 'http://localhost';

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
  return { store, env: { PB_KV: kv } };
}

function seedSession(store, token = 'test-session') {
  const account = {
    id: 'acc-test',
    name: 'Tester',
    tier: 'free',
    status: 'active',
    tokenBalance: 1000,
    tokenUsed: 0,
    creditBalance: 0,
    creditUsed: 0,
  };
  store.set(`account:${account.id}`, JSON.stringify(account));
  store.set(`session:${token}`, account.id);
  return { account, token };
}

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

test('POST /api/auth/api-key membuat key tanpa error 500', async () => {
  const { store, env } = makeEnv();
  const { token } = seedSession(store);

  const res = await call(env, '/api/auth/api-key', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = await res.json();

  assert.equal(res.status, 200, JSON.stringify(body));
  assert.equal(body.ok, true);
  assert.match(body.apiKey, /^pb_[0-9a-f]{32}$/);
  assert.equal(body.prefix, body.apiKey.slice(0, 8));

  // Key disimpan sebagai hash (key mentah tidak pernah masuk KV).
  const hash = await crypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(body.apiKey));
  const keyHash = Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  assert.ok(store.has(`apikey:${keyHash}`));

  // Log audit ikut tercatat lengkap dengan nama akun.
  const logs = JSON.parse(store.get('apikey_logs'));
  assert.equal(logs.length, 1);
  assert.equal(logs[0].accountId, 'acc-test');
  assert.equal(logs[0].accountName, 'Tester');
  assert.equal(logs[0].action, 'create');
});

test('GET lalu DELETE /api/auth/api-key memakai sesi yang sama', async () => {
  const { store, env } = makeEnv();
  const { token } = seedSession(store);

  const created = await call(env, '/api/auth/api-key', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
  });
  const { apiKey, prefix } = await created.json();

  const check = await call(env, '/api/auth/api-key', {
    headers: { Authorization: `Bearer ${token}` },
  });
  const status = await check.json();
  assert.equal(check.status, 200);
  assert.equal(status.hasKey, true);
  assert.equal(status.prefix, prefix);

  const removed = await call(env, '/api/auth/api-key', {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${token}` },
  });
  const deleteBody = await removed.json();
  assert.equal(removed.status, 200);
  assert.ok(deleteBody.deleteAt > Date.now());

  const after = await call(env, '/api/auth/api-key', {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal((await after.json()).hasKey, false);

  // Key yang dijadwalkan hapus tidak boleh dipakai di gateway.
  const gateway = await call(env, '/api/gateway/models', {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  const gatewayBody = await gateway.json();
  assert.equal(gateway.status, 403);
  assert.equal(gatewayBody.error, 'API key is pending deletion.');
});

test('endpoint API key menolak request tanpa sesi', async () => {
  const { env } = makeEnv();
  for (const method of ['GET', 'POST', 'DELETE']) {
    const res = await call(env, '/api/auth/api-key', { method });
    assert.equal(res.status, 401);
    assert.equal(
      (await res.json()).error,
      'Login required to manage API keys.',
    );
  }
});
