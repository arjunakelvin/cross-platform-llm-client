// Local dev harness: serves build/web and runs the worker with an in-memory
// KV so the admin dashboard and Discord config can be tested without
// deploying to Cloudflare. NOT for production.
//
//   node proxy/dev-server.mjs [port]
//
// Admin key for local testing: dev-admin-key

import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The worker is an ES module but keeps the .js extension for Cloudflare;
// a temp .mjs copy avoids Node's CJS-by-default rule for .js files.
const workerSource = await readFile(
  new URL('./cloudflare-worker.js', import.meta.url), 'utf8');
const workerCopy = path.join(
  path.dirname(fileURLToPath(import.meta.url)), '.worker-dev.mjs');
await writeFile(workerCopy, workerSource);
const { default: worker } = await import(pathToFileURL(workerCopy).href);

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../build/web');
const port = Number(globalThis.process?.argv?.[2] || 8090);

const store = new Map();
const kv = {
  async get(key) {
    const entry = store.get(key);
    if (!entry) return null;
    if (entry.expires && entry.expires < Date.now()) {
      store.delete(key);
      return null;
    }
    return entry.value;
  },
  async put(key, value, opts = {}) {
    store.set(key, {
      value: String(value),
      expires: opts.expirationTtl ? Date.now() + opts.expirationTtl * 1000 : 0,
    });
  },
  async delete(key) {
    store.delete(key);
  },
  async list({ prefix } = {}) {
    const keys = [...store.keys()]
      .filter((k) => !prefix || k.startsWith(prefix))
      .map((name) => ({ name }));
    return { keys, list_complete: true, cursor: '' };
  },
};
const env = { PB_KV: kv, ADMIN_KEY: 'dev-admin-key' };

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.wasm': 'application/wasm',
  '.ico': 'image/x-icon',
};

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://localhost:${port}`);

    // Dev-only: buat akun + sesi palsu supaya alur API key & gateway bisa
    // dites tanpa Discord OAuth. Tidak ada di Worker produksi.
    if (url.pathname === '/api/dev/session' && req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      let body = {};
      try {
        body = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      } catch {
        body = {};
      }
      const id = String(body.id || 'dev-user');
      const token = String(body.token || `dev-session-${id}`);
      const account = {
        id,
        name: String(body.name || 'Dev User'),
        role: body.role === 'admin' ? 'admin' : 'user',
        tier: String(body.tier || 'free'),
        tokenBalance: Number(body.tokenBalance) || 1000000,
        tokenUsed: Number(body.tokenUsed) || 0,
        creditBalance: Number(body.creditBalance) || 0,
        creditUsed: Number(body.creditUsed) || 0,
        tokenResetDays: 1,
        lastReset: Date.now(),
        status: 'active',
        discordId: '',
        createdAt: Date.now(),
      };
      store.set(`account:${id}`, {
        value: JSON.stringify(account), expires: 0,
      });
      store.set(`session:${token}`, { value: id, expires: 0 });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, token, account }));
      return;
    }

    // Dev-only: login Discord palsu supaya alur login aplikasi bisa
    // dites tanpa kredensial OAuth Discord asli. Tidak ada di Worker produksi.
    if (url.pathname === '/api/auth/discord' && req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      let body = {};
      try {
        body = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      } catch {
        body = {};
      }
      const code = String(body.code || '');
      if (code === 'dev-login' || code.startsWith('dev-login:')) {
        // "dev-login:<id>" → pakai akun/id tertentu (untuk testing UI).
        const id = code.includes(':')
          ? code.split(':').slice(1).join(':').trim()
          : String(body.id || 'dev-user');
        const token = `dev-session-${id}`;
        const account = {
          id,
          name: String(body.name || 'Dev User'),
          role: body.role === 'admin' ? 'admin' : 'user',
          tier: String(body.tier || 'vip'),
          tokenBalance: Number(body.tokenBalance) || 20000000,
          tokenUsed: Number(body.tokenUsed) || 0,
          creditBalance: Number(body.creditBalance) || 10,
          creditUsed: 0,
          tokenResetDays: 1,
          lastReset: Date.now(),
          status: 'active',
          discordId: id,
          createdAt: Date.now(),
        };
        store.set(`account:${id}`, {
          value: JSON.stringify(account), expires: 0,
        });
        store.set(`session:${token}`, { value: id, expires: 0 });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          token,
          user: { id, username: account.name, email: '' },
          account,
        }));
        return;
      }
    }

    if (url.pathname.startsWith('/api')) {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      const request = new Request(url.toString(), {
        method: req.method,
        headers: req.headers,
        body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
      });
      const response = await worker.fetch(request, env);
      res.writeHead(response.status, Object.fromEntries(response.headers));
      res.end(Buffer.from(await response.arrayBuffer()));
      return;
    }

    let filePath = path.join(root, decodeURIComponent(url.pathname));
    if (url.pathname.endsWith('/')) filePath = path.join(filePath, 'index.html');
    if (!existsSync(filePath)) filePath = path.join(root, 'index.html');
    const data = await readFile(filePath);
    res.writeHead(200, {
      'Content-Type': types[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  } catch (error) {
    console.error('[dev-server]', error);
    if (res.headersSent) {
      res.end();
      return;
    }
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(String(error));
  }
});

server.listen(port, () => {
  console.log(`Dev server: http://localhost:${port}`);
  console.log(`Admin dashboard: http://localhost:${port}/admin/ (key: dev-admin-key)`);
});