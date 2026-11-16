// Test plans berbayar (credit pack + membership VIP/Pro).
//
// Fitur yang diuji:
// 1. GET /api/gateway/plans mengembalikan daftar paket untuk user login.
// 2. Admin menyimpan paket & wallet pembayaran (ShopeePay/GoPay).
// 3. User membuat pesanan (order) → muncul di daftar pesanan admin.
// 4. User mengunggah bukti pembayaran (data URL gambar).
// 5. Admin approve → kredit/token/tier otomatis masuk ke akun; order
//    tidak bisa di-approve dua kali.
// 6. Admin reject → order ditandai rejected, saldo tidak berubah.
//
// Jalankan: node --test proxy/plans.test.mjs

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
const SESSION = 'session-plans-1';
const PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const MP4_DATA_URL =
  'data:video/mp4;base64,' + Buffer.from([0, 1, 2, 3, 4, 5, 6, 7]).toString('base64');

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

function seedAccount(store, account = {}) {
  store.set('account:u1', JSON.stringify({
    id: 'u1',
    name: 'user',
    tier: 'free',
    status: 'active',
    tokenBalance: 100000,
    tokenUsed: 0,
    creditBalance: 1,
    creditUsed: 0,
    ...account,
  }));
  store.set(`session:${SESSION}`, 'u1');
}

function seedWallet(store, wallet = {}) {
  store.set('payment_wallets', JSON.stringify([{
    id: 'shopeepay-1',
    type: 'shopeepay',
    label: 'ShopeePay',
    account: '0812-3456-7890',
    note: 'A/N Kelvin',
    active: true,
    ...wallet,
  }]));
}

function call(env, path, options = {}) {
  return worker.fetch(new Request(`${ORIGIN}${path}`, {
    ...options,
    headers: { Origin: ORIGIN, ...(options.headers || {}) },
  }), env);
}

function authHeader(extra = {}) {
  return { Authorization: `Bearer ${SESSION}`, ...extra };
}

function jsonHeader(extra = {}) {
  return { 'Content-Type': 'application/json', ...authHeader(extra) };
}

test('GET /api/gateway/plans menampilkan paket untuk user login', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);

  const res = await call(env, '/api/gateway/plans', {
    headers: authHeader(),
  });
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.ok(Array.isArray(body.data));
  assert.ok(body.data.length >= 5);
  const best = body.data.find((p) => p.id === 'credit-best');
  assert.equal(best.priceIdr, 250000);
  assert.equal(best.credits, 30);

  // Nonaktif tidak ditampilkan ke user.
  store.set('plans', JSON.stringify([
    { id: 'x1', kind: 'credit', name: 'X', priceIdr: 1000, credits: 1,
      tier: 'none', tokenBonus: 0, dailyReqLimit: 0, active: false },
  ]));
  const res2 = await call(env, '/api/gateway/plans', {
    headers: authHeader(),
  });
  const body2 = await res2.json();
  assert.equal(body2.data.length, 0);
});

test('admin menyimpan paket & wallet; user bisa pesan + approve', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedWallet(store, { type: 'gopay', account: '0899-1111-2222' });

  const put = await call(env, '/api/admin/plans', {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      plans: [
        { id: 'p-credit-1', kind: 'credit', name: 'Credit A', priceIdr: 100000,
          credits: 7, tokenBonus: 1000000, tier: 'none', dailyReqLimit: 0,
          active: true, sort: 1 },
        { id: 'p-vip-1', kind: 'membership', name: 'VIP Set', priceIdr: 150000,
          credits: 2, tokenBonus: 5000000, tier: 'vip', dailyReqLimit: 25,
          active: true, sort: 2 },
      ],
    }),
  });
  assert.equal(put.status, 200);

  // User pesan VIP.
  const order = await call(env, '/api/gateway/plans/order', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ planId: 'p-vip-1', method: 'gopay' }),
  });
  const orderBody = await order.json();
  assert.equal(order.status, 200);
  assert.equal(orderBody.order.status, 'pending');
  assert.equal(orderBody.order.priceIdr, 150000);
  assert.equal(orderBody.wallets[0].type, 'gopay');

  // User unggah bukti.
  const proof = await call(env, '/api/gateway/plans/order/proof', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ orderId: orderBody.order.id, dataUrl: PNG_DATA_URL }),
  });
  assert.equal(proof.status, 200);

  // Admin lihat pesanan pending.
  const list = await call(env, '/api/admin/plan-orders?status=pending', {
    headers: { 'X-Admin-Key': ADMIN_KEY },
  });
  const listBody = await list.json();
  assert.equal(listBody.orders.length, 1);
  assert.ok(listBody.orders[0].proof.startsWith('data:image/'));

  // Admin approve → saldo/tier/req masuk.
  const approve = await call(env, `/api/admin/plan-orders/${orderBody.order.id}/approve`, {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY },
  });
  const approved = await approve.json();
  assert.equal(approve.status, 200);
  assert.equal(approved.account.tier, 'vip');
  assert.equal(approved.account.dailyRequestLimit, 25);
  assert.equal(approved.account.creditBalance, 3); // 1 + 2
  assert.equal(approved.account.tokenBalance, 5100000); // 100k + 5M token bonus

  // Approve dua kali ditolak.
  const again = await call(env, `/api/admin/plan-orders/${orderBody.order.id}/approve`, {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY },
  });
  assert.equal(again.status, 409);
});

test('order rejected → saldo tidak berubah', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedWallet(store);

  const order = await call(env, '/api/gateway/plans/order', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ planId: 'membership-vip', method: 'shopeepay' }),
  });
  const orderBody = await order.json();

  const reject = await call(env, `/api/admin/plan-orders/${orderBody.order.id}/reject`, {
    method: 'POST',
    headers: { 'X-Admin-Key': ADMIN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason: 'Nominal salah.' }),
  });
  assert.equal(reject.status, 200);

  const account = JSON.parse(store.get('account:u1'));
  assert.equal(account.creditBalance, 1);
  assert.equal(account.tier, 'free');

  // User melihat status rejected.
  const mine = await call(env, '/api/gateway/plans/orders', {
    headers: authHeader(),
  });
  const mineBody = await mine.json();
  assert.equal(mineBody.orders[0].status, 'rejected');
});

test('order ditolak kalau belum ada wallet', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  // Tidak ada wallet: admin belum mengisi ACC.
  const order = await call(env, '/api/gateway/plans/order', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ planId: 'credit-starter', method: 'shopeepay' }),
  });
  assert.equal(order.status, 503);
});

test('cron scheduled menghapus bukti pembayaran > 3 hari', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedWallet(store);

  // Buat pesanan lewat API, lalu unggah bukti untuknya.
  const created = await call(env, '/api/gateway/plans/order', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ planId: 'credit-starter', method: 'shopeepay' }),
  });
  const orderBody = await created.json();
  const upload = await call(env, '/api/gateway/plans/order/proof', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ orderId: orderBody.order.id, dataUrl: PNG_DATA_URL }),
  });
  assert.equal(upload.status, 200);

  // Sisipkan pesanan lama dengan bukti video (4 hari lalu).
  const oldProof = MP4_DATA_URL;
  const orders = JSON.parse(store.get('plan_orders'));
  orders.unshift({
    id: 'po_old_1',
    accountId: 'u1',
    accountName: 'user',
    planId: 'credit-starter',
    planName: 'Starter',
    priceIdr: 50000,
    method: 'shopeepay',
    status: 'pending',
    proof: oldProof,
    createdAt: Date.now() - 4 * 24 * 60 * 60 * 1000,
    updatedAt: Date.now() - 4 * 24 * 60 * 60 * 1000,
    grants: {},
  });
  store.set('plan_orders', JSON.stringify(orders));

  // Jalankan handler cron yang sama dengan wrangler. Cloudflare menjalankan
  // waitUntil; di sini kita tangkap & await promise-nya secara eksplisit.
  if (typeof worker.scheduled !== 'function') {
    assert.fail('worker.scheduled harus ada di export default');
  }
  let pending;
  await worker.scheduled({}, env, {
    waitUntil: (p) => { pending = p; },
  });
  if (pending) await pending;

  const after = JSON.parse(store.get('plan_orders'));
  const old = after.find((o) => o.id === 'po_old_1');
  assert.equal(old.proof, '');
  assert.ok(old.proofDeletedAt, 'bukti lama harus ditandai terhapus');

  // Pesanan yang baru tidak terpengaruh.
  const fresh = after.find((o) => o.id === orderBody.order.id);
  if (fresh) {
    assert.notEqual(fresh.proof, '');
  }
});

test('method pembayaran selain shopeepay/gopay ditolak', async () => {
  const { store, env } = makeEnv();
  seedAccount(store);
  seedWallet(store);

  const order = await call(env, '/api/gateway/plans/order', {
    method: 'POST',
    headers: jsonHeader(),
    body: JSON.stringify({ planId: 'credit-starter', method: 'transfer' }),
  });
  assert.equal(order.status, 400);
});
