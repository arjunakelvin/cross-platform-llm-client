/**
 * AI-Agent PiercingBlow — Cloudflare Worker.
 *
 * Two jobs on the route <your-domain>/api*:
 *
 * 1. CORS proxy for OpenAI-compatible gateways:
 *      POST /api?url=https%3A%2F%2Fgateway.example%2Fv1%2Fchat%2Fcompletions
 *
 * 2. Auth + admin backend for Discord login and account tiers:
 *      GET    /api/auth/config          public login config (no secrets)
 *      POST   /api/auth/discord         {code} -> session token + account
 *      GET    /api/auth/me              Bearer session -> user + account
 *      POST   /api/auth/logout          Bearer session -> revoke
 *      GET    /api/admin/health         X-Admin-Key
 *      GET    /api/admin/config         X-Admin-Key (secret masked)
 *      PATCH  /api/admin/config         X-Admin-Key
 *      GET    /api/admin/accounts       X-Admin-Key
 *      POST   /api/admin/accounts/<id>  X-Admin-Key (upsert)
 *      DELETE /api/admin/accounts/<id>  X-Admin-Key
 *
 * Bindings (wrangler.toml / dashboard):
 *   PB_KV      KV namespace for config, accounts and sessions
 *   ADMIN_KEY  secret string; the private /admin/ dashboard asks for it
 *              (set with `wrangler secret put ADMIN_KEY`)
 *
 * The Discord client secret is stored ONLY here (KV). Browsers never see it:
 * the code->token exchange happens inside this worker.
 *
 * SECURITY: keep this on a host you control, HTTPS only, never log headers
 * or bodies (they carry API keys and session tokens).
 */

const ALLOWED_ORIGINS = new Set([
  'https://piercingblow.ai.id',
  'https://www.piercingblow.ai.id',
]);

const SESSION_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 days
const CONFIG_KEY = 'config';

const DEFAULT_CONFIG = {
  discord: { enabled: false, clientId: '', clientSecret: '', redirectUri: '' },
  tiers: ['free', 'pro', 'vip'],
  defaultTier: 'free',
  guestTokenBalance: 10000000, // 10M tanpa login
  loginTokenBalance: 20000000, // 20M setelah login Discord (10M + bonus 10M)
  tokenResetDays: 1, // durasi reset token (hari), bisa diubah di dashboard
  botSecretKey: '', // optional secret for Discord bot API verification
  aiServerUrl: '',
  localCloudKey: '',
  // Server Manager (lihat server/README.md): alamat API manager + secret
  // yang dipakai web client untuk start/stop server AI.
  managerUrl: '',
  managerSecretKey: '',
};

function isAllowedOrigin(origin) {
  if (!origin) return true; // same-origin requests send no Origin
  if (ALLOWED_ORIGINS.has(origin)) return true;
  if (/^https:\/\/[a-z0-9_-]+\.github\.io$/i.test(origin)) return true;
  // Local development servers.
  return /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
}

function corsHeaders(request) {
  const origin = request.headers.get('origin') || '';
  const headers = {
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
      'authorization, content-type, accept, x-admin-key, x-secret-key',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
  if (isAllowedOrigin(origin)) {
    headers['Access-Control-Allow-Origin'] = origin || '*';
  }
  return headers;
}

function jsonResponse(request, status, data) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders(request),
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

function textResponse(request, status, message) {
  return new Response(message, {
    status,
    headers: {
      ...corsHeaders(request),
      'Content-Type': 'text/plain; charset=utf-8',
    },
  });
}

async function getJson(kv, key, fallback) {
  const raw = await kv.get(key);
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

async function getConfig(env) {
  const stored = await getJson(env.PB_KV, CONFIG_KEY, {});
  return {
    ...DEFAULT_CONFIG,
    ...stored,
    discord: { ...DEFAULT_CONFIG.discord, ...(stored.discord || {}) },
  };
}

// ── Cache model list + statistik hit rate ────────────────────────────────
// Daftar model dibaca dari KV tiap load app. Cache ini mempercepatnya dan
// hit rate-nya ditampilkan sebagai statistik di tab Model List.

const CACHE_STATS_KEY = 'cache_stats';

async function cachedJson(env, key, ttlSeconds, producer) {
  const raw = await env.PB_KV.get(key);
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      await recordCacheStat(env, true);
      return { value: parsed, hit: true };
    } catch {
      // Cache rusak — buat ulang.
    }
  }
  const value = await producer();
  try {
    await env.PB_KV.put(key, JSON.stringify(value), {
      expirationTtl: ttlSeconds,
    });
  } catch (_) {
    // Cache opsional; gagal menyimpan tidak boleh menggagalkan request.
  }
  await recordCacheStat(env, false);
  return { value, hit: false };
}

async function recordCacheStat(env, hit) {
  try {
    const stats = await getJson(env.PB_KV, CACHE_STATS_KEY, {});
    const hour = new Date().toISOString().slice(0, 13); // YYYY-MM-DDTHH
    const bucket = stats[hour] || { hits: 0, misses: 0 };
    if (hit) bucket.hits = (Number(bucket.hits) || 0) + 1;
    else bucket.misses = (Number(bucket.misses) || 0) + 1;
    stats[hour] = bucket;
    const keys = Object.keys(stats).sort();
    while (keys.length > 48) delete stats[keys.shift()];
    await env.PB_KV.put(CACHE_STATS_KEY, JSON.stringify(stats));
  } catch (_) {
    // Statistik tidak boleh menggagalkan request.
  }
}

/// Statistik cache 24 jam terakhir: hit rate + jumlah hit/miss per jam.
async function cacheStats(env) {
  const stats = await getJson(env.PB_KV, CACHE_STATS_KEY, {});
  const now = new Date();
  const hours = [];
  let hits = 0;
  let misses = 0;
  for (let i = 23; i >= 0; i--) {
    const date = new Date(now.getTime() - i * 60 * 60 * 1000);
    const key = date.toISOString().slice(0, 13);
    const bucket = stats[key] || { hits: 0, misses: 0 };
    const h = Number(bucket.hits) || 0;
    const m = Number(bucket.misses) || 0;
    hits += h;
    misses += m;
    hours.push({
      hour: key.slice(11) + ':00',
      hits: h,
      misses: m,
    });
  }
  const total = hits + misses;
  return {
    hitRate: total > 0 ? Math.round((hits / total) * 1000) / 10 : 0,
    hits,
    misses,
    total,
    hours,
  };
}

function publicConfig(request, config) {
  const origin = new URL(request.url).origin;
  return {
    discord: {
      enabled: !!config.discord.enabled,
      clientId: config.discord.clientId || '',
      redirectUri: config.discord.redirectUri || `${origin}/auth/discord`,
    },
    tiers: Array.isArray(config.tiers) ? config.tiers : DEFAULT_CONFIG.tiers,
    defaultTier: config.defaultTier || 'free',
    guestTokenBalance: config.guestTokenBalance ?? DEFAULT_CONFIG.guestTokenBalance,
    loginTokenBalance: config.loginTokenBalance ?? DEFAULT_CONFIG.loginTokenBalance,
    tokenResetDays: config.tokenResetDays ?? DEFAULT_CONFIG.tokenResetDays,
    // Hanya alamat server yang publik. Secret key TIDAK pernah dibuka di
    // endpoint publik — dikirim ke user yang sudah login lewat /api/auth/me.
    aiServerUrl: config.aiServerUrl || '',
    managerUrl: config.managerUrl || '',
  };
}

function adminAuthorized(request, env) {
  const expected = env.ADMIN_KEY || '';
  if (!expected) return false;
  return request.headers.get('x-admin-key') === expected;
}

function bearerToken(request) {
  const header = request.headers.get('authorization') || '';
  return header.startsWith('Bearer ') ? header.slice(7).trim() : '';
}

async function sessionAccount(env, request) {
  const token = bearerToken(request);
  if (!token) return null;
  const accountId = await env.PB_KV.get(`session:${token}`);
  if (!accountId) return null;
  const account = await getJson(env.PB_KV, `account:${accountId}`, null);
  if (!account) return null;
  return { token, account };
}

async function handleAuth(request, env, pathname) {
  const config = await getConfig(env);

  if (pathname === '/api/auth/config' && request.method === 'GET') {
    const origin = new URL(request.url).origin;
    // Daftar model + server di-cache supaya request config (dipakai app
    // saat start) tidak membaca KV terus-menerus. Hit rate-nya tampil di
    // tab Model List sebagai statistik.
    const cached = await cachedJson(env, 'config_models_cache', 60, async () => {
      const serverModels = await getJson(env.PB_KV, 'server_models', []);
      const mgrServers = await getJson(env.PB_KV, 'mgr_servers', []);
      // Daftar server publik (tanpa secret/API key backend). Dipakai aplikasi
      // untuk tab Model List dan provider Local AI.
      const modelApiByServer = new Map();
      for (const m of serverModels) {
        const sid = String((m && m.serverId) || '');
        if (sid && !modelApiByServer.has(sid) && m.apiUrl) {
          modelApiByServer.set(sid, String(m.apiUrl));
        }
      }
      const servers = mgrServers
        .filter((s) => s && s.id && s.enabled !== false)
        .map((s) => ({
          id: String(s.id),
          name: String(s.name || s.id),
          baseUrl: String(s.baseUrl ||
            modelApiByServer.get(String(s.id)) || ''),
          runtime: String(s.runtime || ''),
        }));
      const serverById = new Map(servers.map((s) => [s.id, s]));
      const models = serverModels
        .filter((m) => m && m.modelId)
        .filter((m) => !m.serverId || serverById.has(String(m.serverId)))
        .map((m) => {
          const server = serverById.get(String(m.serverId || ''));
          return {
            modelId: String(m.modelId),
            // Nama model asli di daemon; dipakai aplikasi saat memanggil
            // server inference langsung (tanpa gateway) sebagai fallback.
            backendModelId: String(m.backendModelId || m.modelId),
            name: String(m.name || m.modelId),
            serverId: String(m.serverId || ''),
            serverName: server ? server.name : '',
            serverBaseUrl: server
              ? String(m.apiUrl || server.baseUrl || '')
              : String(m.apiUrl || ''),
            runtime: String(m.runtime ||
              (server ? server.runtime : '') || ''),
            tierAccess: Array.isArray(m.tierAccess)
              ? m.tierAccess
              : ['free', 'pro', 'vip'],
            contextSize: Number(m.contextSize) || 0,
            maxOutput: Number(m.maxOutput) || 0,
            pricing: m.pricing || {},
          };
        });
      return { servers, models };
    });
    const servers = cached.value.servers || [];
    const models = cached.value.models || [];
    const firstServerUrl = servers.length ? servers[0].baseUrl : '';
    return jsonResponse(request, 200, {
      ...publicConfig(request, config),
      aiServerUrl: config.aiServerUrl || firstServerUrl,
      servers,
      models,
      gatewayBaseUrl: `${origin}/api/gateway/v1`,
    });
  }

  // GET /api/auth/cache-stats — statistik cache model list (24 jam).
  if (pathname === '/api/auth/cache-stats' && request.method === 'GET') {
    return jsonResponse(request, 200, await cacheStats(env));
  }

  if (pathname === '/api/auth/discord' && request.method === 'POST') {
    if (!config.discord.enabled) {
      return jsonResponse(request, 403, { error: 'Discord login is disabled.' });
    }
    if (!config.discord.clientId || !config.discord.clientSecret) {
      return jsonResponse(request, 503, {
        error: 'Discord OAuth is not configured on the server yet.',
      });
    }
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const code = (body && body.code ? String(body.code) : '').trim();
    if (!code) {
      return jsonResponse(request, 400, { error: 'Missing OAuth code.' });
    }
    const origin = new URL(request.url).origin;
    const redirectUri = config.discord.redirectUri || `${origin}/auth/discord`;

    // Server-side exchange: the client secret never reaches the browser.
    const tokenRes = await fetch('https://discord.com/api/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: config.discord.clientId,
        client_secret: config.discord.clientSecret,
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri,
      }),
    });
    if (!tokenRes.ok) {
      const detail = await tokenRes.text();
      return jsonResponse(request, 401, {
        error: `Discord token exchange failed (HTTP ${tokenRes.status}).`,
        detail: detail.slice(0, 300),
      });
    }
    const tokenData = await tokenRes.json();
    const accessToken = tokenData.access_token;
    if (!accessToken) {
      return jsonResponse(request, 401, { error: 'Discord returned no token.' });
    }

    const userRes = await fetch('https://discord.com/api/users/@me', {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!userRes.ok) {
      return jsonResponse(request, 502, {
        error: `Could not fetch Discord profile (HTTP ${userRes.status}).`,
      });
    }
    const discordUser = await userRes.json();
    const discordId = String(discordUser.id || '');
    if (!discordId) {
      return jsonResponse(request, 502, { error: 'Discord profile has no id.' });
    }

    // Resolve the account: direct link first, then a pre-linked row.
    let accountId = await env.PB_KV.get(`link:${discordId}`);
    let account = accountId
      ? await getJson(env.PB_KV, `account:${accountId}`, null)
      : null;
    if (!account) {
      const list = await env.PB_KV.list({ prefix: 'account:' });
      for (const key of list.keys) {
        const candidate = await getJson(env.PB_KV, key.name, null);
        if (candidate && String(candidate.discordId || '') === discordId) {
          accountId = String(candidate.id);
          account = candidate;
          break;
        }
      }
    }
    const now = Date.now();
    const username = String(
      discordUser.username || discordUser.global_name || 'discord-user',
    );
    if (!account) {
      accountId = discordId;
      account = {
        id: accountId,
        name: username,
        role: 'user',
        tier: config.defaultTier || 'free',
        tokenBalance: config.loginTokenBalance || 20000000,
        tokenUsed: 0,
        creditBalance: 0,
        creditUsed: 0,
        tokenResetDays: config.tokenResetDays || 1,
        lastReset: now,
        status: 'active',
        discordId,
        createdAt: now,
      };
    } else {
      account.name = username;
      account.discordId = discordId;
    }
    if (account.status === 'banned') {
      return jsonResponse(request, 403, { error: 'This account is banned.' });
    }
    await env.PB_KV.put(`account:${accountId}`, JSON.stringify(account));
    await env.PB_KV.put(`link:${discordId}`, accountId);

    const sessionToken = `${crypto.randomUUID()}${crypto.randomUUID()}`.replace(/-/g, '');
    await env.PB_KV.put(`session:${sessionToken}`, accountId, {
      expirationTtl: SESSION_TTL_SECONDS,
    });
    return jsonResponse(request, 200, {
      token: sessionToken,
      user: {
        id: discordId,
        username,
        email: String(discordUser.email || ''),
      },
      account,
    });
  }

  if (pathname === '/api/auth/me' && request.method === 'GET') {
    const session = await sessionAccount(env, request);
    if (!session) {
      return jsonResponse(request, 401, { error: 'Invalid or expired session.' });
    }
    if (session.account.status === 'banned') {
      return jsonResponse(request, 403, { error: 'This account is banned.' });
    }
    return jsonResponse(request, 200, {
      user: {
        id: String(session.account.discordId || session.account.id),
        username: session.account.name || '',
      },
      account: session.account,
      // Secret inference TIDAK dikirim ke user. Aplikasi memakai API key
      // milik user lewat gateway; gateway yang menambahkan secret backend.
    });
  }

  if (pathname === '/api/auth/logout' && request.method === 'POST') {
    const token = bearerToken(request);
    if (token) await env.PB_KV.delete(`session:${token}`);
    return jsonResponse(request, 200, { ok: true });
  }

  return jsonResponse(request, 404, { error: 'Unknown auth endpoint.' });
}

async function handleAdmin(request, env, pathname) {
  if (!env.ADMIN_KEY) {
    return jsonResponse(request, 503, {
      error: 'ADMIN_KEY is not set on the worker. Run: wrangler secret put ADMIN_KEY',
    });
  }
  if (!adminAuthorized(request, env)) {
    return jsonResponse(request, 401, { error: 'Invalid admin key.' });
  }

  if (pathname === '/api/admin/health' && request.method === 'GET') {
    return jsonResponse(request, 200, { ok: true, service: 'piercingblow-admin' });
  }

  if (pathname === '/api/admin/config') {
    const config = await getConfig(env);
    if (request.method === 'GET') {
      return jsonResponse(request, 200, {
        discord: {
          enabled: !!config.discord.enabled,
          clientId: config.discord.clientId || '',
          redirectUri: config.discord.redirectUri || '',
          hasSecret: !!config.discord.clientSecret,
        },
        tiers: config.tiers,
        defaultTier: config.defaultTier,
        defaultTokenBalance: config.defaultTokenBalance ?? config.loginTokenBalance ?? 20000000,
        guestTokenBalance: config.guestTokenBalance ?? DEFAULT_CONFIG.guestTokenBalance,
        loginTokenBalance: config.loginTokenBalance ?? DEFAULT_CONFIG.loginTokenBalance,
        tokenResetDays: config.tokenResetDays ?? DEFAULT_CONFIG.tokenResetDays,
        botSecretKey: config.botSecretKey || '',
        hasBotSecret: !!config.botSecretKey,
        aiServerUrl: config.aiServerUrl || '',
        localCloudKey: config.localCloudKey || '',
        managerUrl: config.managerUrl || '',
        managerSecretKey: config.managerSecretKey || '',
      });
    }
    if (request.method === 'PATCH') {
      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
      }
      const next = { ...config, discord: { ...config.discord } };
      if (body.discord && typeof body.discord === 'object') {
        if (typeof body.discord.enabled === 'boolean') {
          next.discord.enabled = body.discord.enabled;
        }
        if (typeof body.discord.clientId === 'string') {
          next.discord.clientId = body.discord.clientId.trim();
        }
        if (typeof body.discord.redirectUri === 'string') {
          next.discord.redirectUri = body.discord.redirectUri.trim();
        }
        // Empty secret = keep the existing one (it is never echoed back).
        if (typeof body.discord.clientSecret === 'string' &&
            body.discord.clientSecret.trim().length > 0) {
          next.discord.clientSecret = body.discord.clientSecret.trim();
        }
      }
      if (Array.isArray(body.tiers) && body.tiers.length > 0) {
        next.tiers = [...new Set(body.tiers.map((t) => String(t).trim()).filter(Boolean))];
      }
      if (typeof body.defaultTier === 'string' && body.defaultTier.trim()) {
        next.defaultTier = body.defaultTier.trim();
      }
      if (typeof body.defaultTokenBalance === 'number' &&
          body.defaultTokenBalance >= 0) {
        next.defaultTokenBalance = Math.floor(body.defaultTokenBalance);
      }
      if (typeof body.guestTokenBalance === 'number' &&
          body.guestTokenBalance >= 0) {
        next.guestTokenBalance = Math.floor(body.guestTokenBalance);
      }
      if (typeof body.loginTokenBalance === 'number' &&
          body.loginTokenBalance >= 0) {
        next.loginTokenBalance = Math.floor(body.loginTokenBalance);
      }
      if (typeof body.tokenResetDays === 'number' &&
          body.tokenResetDays > 0) {
        next.tokenResetDays = Math.floor(body.tokenResetDays);
      }
      if (typeof body.botSecretKey === 'string') {
        next.botSecretKey = body.botSecretKey.trim();
      }
      if (typeof body.aiServerUrl === 'string') {
        next.aiServerUrl = body.aiServerUrl.trim();
      }
      if (typeof body.localCloudKey === 'string') {
        next.localCloudKey = body.localCloudKey.trim();
      }
      if (typeof body.managerUrl === 'string') {
        next.managerUrl = body.managerUrl.trim();
      }
      if (typeof body.managerSecretKey === 'string') {
        next.managerSecretKey = body.managerSecretKey.trim();
      }
      if (!next.tiers.includes(next.defaultTier)) {
        next.tiers.unshift(next.defaultTier);
      }
      await env.PB_KV.put(CONFIG_KEY, JSON.stringify(next));
      return jsonResponse(request, 200, { ok: true });
    }
  }

  if (pathname === '/api/admin/accounts' && request.method === 'GET') {
    const list = await env.PB_KV.list({ prefix: 'account:' });
    const accounts = [];
    for (const key of list.keys) {
      const account = await getJson(env.PB_KV, key.name, null);
      if (account) accounts.push(account);
    }
    accounts.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
    return jsonResponse(request, 200, { accounts });
  }

  const accountMatch = pathname.match(/^\/api\/admin\/accounts\/([^/]+)$/);
  if (accountMatch) {
    const id = decodeURIComponent(accountMatch[1]);
    if (request.method === 'POST') {
      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
      }
      if (!body || typeof body !== 'object') {
        return jsonResponse(request, 400, { error: 'Missing account body.' });
      }
      const existing = await getJson(env.PB_KV, `account:${id}`, {});
      const now = Date.now();
      const account = {
        id,
        name: String(body.name ?? existing.name ?? ''),
        role: body.role === 'admin' ? 'admin' : 'user',
        tier: String(body.tier ?? existing.tier ?? 'free'),
        tokenBalance: Number.isFinite(+body.tokenBalance)
          ? Math.max(0, Math.floor(+body.tokenBalance))
          : (existing.tokenBalance ?? 0),
        tokenUsed: Number.isFinite(+body.tokenUsed)
          ? Math.max(0, Math.floor(+body.tokenUsed))
          : (existing.tokenUsed ?? 0),
        creditBalance: Number.isFinite(+body.creditBalance)
          ? Math.max(0, +body.creditBalance)
          : (existing.creditBalance ?? 0),
        creditUsed: Number.isFinite(+body.creditUsed)
          ? Math.max(0, +body.creditUsed)
          : (existing.creditUsed ?? 0),
        tokenResetDays: Number.isFinite(+body.tokenResetDays)
          ? Math.max(0, Math.floor(+body.tokenResetDays))
          : (existing.tokenResetDays ?? 0),
        lastReset: Number.isFinite(+body.lastReset)
          ? Math.floor(+body.lastReset)
          : (existing.lastReset ?? now),
        status: body.status === 'banned' ? 'banned' : 'active',
        discordId: String(body.discordId ?? existing.discordId ?? '').trim(),
        createdAt: existing.createdAt ?? now,
      };
      await env.PB_KV.put(`account:${id}`, JSON.stringify(account));
      if (account.discordId) {
        await env.PB_KV.put(`link:${account.discordId}`, id);
      }
      return jsonResponse(request, 200, { ok: true, account });
    }
    if (request.method === 'DELETE') {
      const existing = await getJson(env.PB_KV, `account:${id}`, null);
      await env.PB_KV.delete(`account:${id}`);
      if (existing && existing.discordId) {
        await env.PB_KV.delete(`link:${existing.discordId}`);
      }
      return jsonResponse(request, 200, { ok: true });
    }
  }

  return jsonResponse(request, 404, { error: 'Unknown admin endpoint.' });
}

// ── Server manager config (disimpan di KV, diedit dari dashboard) ────────
//
// Ini BUKAN config proses server Python. Daemon manager tetap membaca
// servers.json sendiri untuk start/stop + statistik CPU/RAM. Entri di sini
// adalah definisi "AI server" yang dipakai gateway/model list aplikasi:
// alamat IP/URL, nama, model, harga input/output, context, max output, tier.

function cleanServerId(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64);
}

function cleanServerEntry(body, existing) {
  const now = Date.now();
  const base = existing || {};
  const keepSecret = (field, value) =>
    typeof value === 'string' && value.trim().length > 0
      ? value.trim()
      : String(base[field] || '');
  return {
    id: cleanServerId(body.id ?? base.id),
    name: String(body.name ?? base.name ?? '').trim(),
    // Satu entri = satu VPS/daemon. Alamat inference dan secret-nya
    // didapat dari daemon manager (servers.json), jadi admin tidak perlu
    // mengetik base URL / secret inference lagi.
    managerUrl: String(body.managerUrl ?? base.managerUrl ?? '').trim(),
    managerKey: keepSecret('managerKey', body.managerKey),
    // Diisi otomatis dari daemon saat deteksi (kompatibilitas lama).
    baseUrl: String(body.baseUrl ?? base.baseUrl ?? '').trim(),
    apiKey: keepSecret('apiKey', body.apiKey),
    runtime: String(body.runtime ?? base.runtime ?? '').trim(),
    enabled: body.enabled === undefined
      ? (base.enabled !== false)
      : !!body.enabled,
    notes: String(body.notes ?? base.notes ?? '').trim(),
    createdAt: base.createdAt || now,
    updatedAt: now,
  };
}

// ── Deteksi model otomatis lewat daemon manager ─────────────────────────
// Daemon Python sudah tahu daftar AI server di VPS-nya: apiUrl publik,
// runtime, dan array "models" di servers.json. Worker hanya membaca
// GET <manager>/servers, jadi dashboard tidak perlu base URL + secret
// inference terpisah.

function normalizeManagerUrl(value) {
  let base = String(value || '').trim().replace(/\/+$/, '');
  if (!base) return '';
  base = base.replace(/\/servers$/i, '').replace(/\/+$/, '');
  if (!/\/manager$/i.test(base)) base += '/manager';
  return base;
}

async function fetchManagerServers(server) {
  const base = normalizeManagerUrl(server.managerUrl);
  if (!base) throw new Error('Manager URL belum diisi.');
  const headers = { Accept: 'application/json' };
  if (server.managerKey) headers['X-Secret-Key'] = server.managerKey;
  let res;
  try {
    res = await fetch(`${base}/servers`, { headers });
  } catch (error) {
    throw new Error(`Tidak bisa menghubungi ${base}/servers: ${error}`);
  }
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} dari ${base}/servers: ${text.slice(0, 180)}`);
  }
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(`Respons ${base}/servers bukan JSON.`);
  }
  if (Array.isArray(payload)) return payload;
  if (payload && Array.isArray(payload.servers)) return payload.servers;
  return [];
}

function detectedModelsFromManager(daemons) {
  const detected = [];
  const seen = new Set();
  for (const daemon of daemons) {
    if (!daemon || typeof daemon !== 'object') continue;
    const daemonId = String(daemon.id || '').trim();
    const apiUrl = String(daemon.apiUrl || '').trim();
    const runtime = String(daemon.runtime || '').trim();
    let ids = Array.isArray(daemon.models) ? daemon.models : [];
    ids = ids.map((id) => String(id || '').trim()).filter(Boolean);
    if (!ids.length && daemon.model) ids = [String(daemon.model).trim()];
    for (const backendId of [...new Set(ids)]) {
      const key = `${daemonId}::${backendId}`;
      if (seen.has(key)) continue;
      seen.add(key);
      detected.push({ backendId, daemonId, apiUrl, runtime });
    }
  }
  return detected;
}

async function syncDetectedModels(env, server, detected) {
  const models = await getJson(env.PB_KV, 'server_models', []);
  const now = Date.now();
  const others = models.filter(
    (m) => String(m.serverId || '') !== String(server.id));
  const existingForServer = models.filter(
    (m) => String(m.serverId || '') === String(server.id));
  const byKey = new Map();
  for (const model of existingForServer) {
    const key = `${model.daemonId || ''}::${model.backendModelId || model.modelId || ''}`;
    if (!byKey.has(key)) byKey.set(key, model);
  }

  const taken = new Set(others.map((m) => String(m.modelId)));
  const added = [];
  const updated = [];
  const kept = [];
  const detectedKeys = new Set();
  for (const item of detected) {
    const key = `${item.daemonId || ''}::${item.backendId}`;
    detectedKeys.add(key);
    const existing = byKey.get(key);
    let modelId = existing ? existing.modelId : item.backendId;
    if (!existing && taken.has(modelId)) {
      // Nama model sama di VPS/proses lain: beri prefix server agar
      // modelId tetap unik untuk gateway.
      let candidate = `${server.id}/${item.backendId}`;
      let suffix = 2;
      while (taken.has(candidate)) {
        candidate = `${server.id}/${item.backendId}-${suffix++}`;
      }
      modelId = candidate;
    }
    taken.add(modelId);
    const entry = {
      modelId,
      backendModelId: item.backendId,
      daemonId: item.daemonId || '',
      name: existing ? (existing.name || item.backendId) : item.backendId,
      serverId: String(server.id),
      serverUrl: item.apiUrl || server.baseUrl || '',
      apiUrl: item.apiUrl || '',
      runtime: item.runtime || server.runtime || '',
      tierAccess: Array.isArray(existing && existing.tierAccess)
        ? existing.tierAccess
        : ['free', 'pro', 'vip'],
      pricing: (existing && existing.pricing) || {},
      contextSize: existing ? (Number(existing.contextSize) || 0) : 0,
      maxOutput: existing ? (Number(existing.maxOutput) || 0) : 0,
      detected: true,
      createdAt: (existing && existing.createdAt) || now,
      updatedAt: now,
    };
    if (existing) updated.push(modelId);
    else added.push(modelId);
    kept.push(entry);
  }

  // Model yang sudah tidak ada di daemon hanya dihapus kalau deteksi
  // mengembalikan daftar (menghindari menghapus semua karena respons kosong).
  const removed = detected.length ? existingForServer
    .filter((m) => !detectedKeys.has(
      `${m.daemonId || ''}::${m.backendModelId || m.modelId || ''}`))
    .map((m) => m.modelId) : [];

  await env.PB_KV.put(
    'server_models', JSON.stringify([...others, ...kept]));
  return { added, updated, removed, total: kept.length };
}

async function detectViaManager(env, server) {
  const daemons = await fetchManagerServers(server);
  const detected = detectedModelsFromManager(daemons);
  const first = daemons.find((d) => d && (d.runtime || d.apiUrl)) || {};
  if (first.runtime) server.runtime = String(first.runtime);
  if (first.apiUrl) server.baseUrl = String(first.apiUrl);
  const sync = await syncDetectedModels(env, server, detected);
  return {
    ok: true,
    count: detected.length,
    models: detected.map((d) => d.backendId),
    daemons: daemons.length,
    ...sync,
  };
}

async function handleAdminServers(request, env, pathname) {
  if (!adminAuthorized(request, env)) {
    return jsonResponse(request, 401, { error: 'Invalid admin key.' });
  }

  if (pathname === '/api/admin/servers' && request.method === 'GET') {
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    return jsonResponse(request, 200, { servers });
  }

  if (pathname === '/api/admin/servers' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const incomingId = cleanServerId(body.id);
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const idx = servers.findIndex((s) => s.id === incomingId);
    const entry = cleanServerEntry(body, idx >= 0 ? servers[idx] : undefined);
    if (!entry.id) {
      return jsonResponse(request, 400, { error: 'Server ID wajib diisi.' });
    }
    if (!entry.managerUrl) {
      return jsonResponse(request, 400, { error: 'Manager URL wajib diisi.' });
    }
    // Deteksi model lewat daemon manager VPS ini (GET <manager>/servers).
    let detection = { ok: false, skipped: true, count: 0, models: [] };
    try {
      detection = await detectViaManager(env, entry);
    } catch (error) {
      detection = {
        ok: false,
        count: 0,
        models: [],
        error: String(error && error.message ? error.message : error),
      };
    }
    if (idx >= 0) {
      entry.createdAt = servers[idx].createdAt || entry.createdAt;
      servers[idx] = entry;
    } else {
      servers.push(entry);
    }
    await env.PB_KV.put('mgr_servers', JSON.stringify(servers));
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, { ok: true, server: entry, detection });
  }

  // POST /api/admin/servers/:id/detect-models — deteksi ulang model.
  const detectMatch = pathname.match(
    /^\/api\/admin\/servers\/([^/]+)\/detect-models$/);
  if (detectMatch && request.method === 'POST') {
    const id = decodeURIComponent(detectMatch[1]);
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const idx = servers.findIndex((s) => String(s.id) === String(id));
    if (idx < 0) {
      return jsonResponse(request, 404, { error: `Server "${id}" tidak ada.` });
    }
    const server = servers[idx];
    try {
      const detection = await detectViaManager(env, server);
      servers[idx] = server;
      await env.PB_KV.put('mgr_servers', JSON.stringify(servers));
      await invalidateModelCaches(env);
      return jsonResponse(request, 200, { ok: true, server, ...detection });
    } catch (error) {
      return jsonResponse(request, 502, {
        ok: false,
        error: String(error && error.message ? error.message : error),
        endpoint: `${normalizeManagerUrl(server.managerUrl)}/servers`,
      });
    }
  }

  const match = pathname.match(/^\/api\/admin\/servers\/([^/]+)$/);
  if (match && request.method === 'DELETE') {
    const id = decodeURIComponent(match[1]);
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const next = servers.filter((s) => s.id !== id);
    await env.PB_KV.put('mgr_servers', JSON.stringify(next));
    // Hapus juga model yang menempel ke server ini supaya tidak orphan.
    const models = await getJson(env.PB_KV, 'server_models', []);
    const kept = models.filter((m) => String(m.serverId || '') !== id);
    if (kept.length !== models.length) {
      await env.PB_KV.put('server_models', JSON.stringify(kept));
    }
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, {
      ok: true,
      deleted: id,
      deletedModels: models.length - kept.length,
    });
  }

  return jsonResponse(request, 404, { error: 'Unknown server endpoint.' });
}

async function handleBotApi(request, env, pathname) {
  const config = await getConfig(env);

  // Autentikasi bot WAJIB. Kalau "Bot API Key" belum diisi di dashboard,
  // endpoint bot ditutup (fail-closed) supaya tidak bisa dibuka tanpa auth.
  const url = new URL(request.url);
  const providedKey = (
    request.headers.get('x-bot-key') ||
    request.headers.get('x-admin-key') ||
    url.searchParams.get('key') ||
    bearerToken(request) ||
    ''
  ).trim();
  const botKey = String(config.botSecretKey || '').trim();
  const adminKey = String(env.ADMIN_KEY || '').trim();
  const allowedByBot = botKey.length > 0 && providedKey === botKey;
  const allowedByAdmin = adminKey.length > 0 && providedKey === adminKey;
  if (!allowedByBot && !allowedByAdmin) {
    return jsonResponse(request, 401, {
      error: 'Invalid or missing Bot API key.',
      hint: 'Isi "Bot API Key" di dashboard admin, lalu kirim header '
        + 'X-Bot-Key (atau Authorization: Bearer / ?key=) dengan nilai itu.',
    });
  }

  // Verification endpoint: GET /api/bot/verify?discord_id=... or POST /api/bot/verify
  if (
    pathname === '/api/bot/verify' ||
    pathname === '/api/discord-bot/verify' ||
    pathname === '/api/discord/verify'
  ) {
    let discordId = '';
    if (request.method === 'GET') {
      discordId = (url.searchParams.get('discord_id') || url.searchParams.get('id') || '').trim();
    } else if (request.method === 'POST') {
      try {
        const body = await request.json();
        discordId = String(body.discord_id || body.discordId || body.id || '').trim();
      } catch {
        return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
      }
    } else {
      return jsonResponse(request, 405, { error: 'Method not allowed. Use GET or POST.' });
    }

    if (!discordId) {
      return jsonResponse(request, 400, {
        error: 'Missing discord_id query parameter or body field.',
      });
    }

    // Lookup linked account
    let accountId = await env.PB_KV.get(`link:${discordId}`);
    let account = accountId ? await getJson(env.PB_KV, `account:${accountId}`, null) : null;

    if (!account) {
      const list = await env.PB_KV.list({ prefix: 'account:' });
      for (const key of list.keys) {
        const candidate = await getJson(env.PB_KV, key.name, null);
        if (candidate && String(candidate.discordId || '') === discordId) {
          accountId = String(candidate.id);
          account = candidate;
          break;
        }
      }
    }

    if (!account) {
      return jsonResponse(request, 200, {
        verified: false,
        discord_id: discordId,
        user: null,
        message: 'Akun Discord belum terdaftar atau belum login di web.',
      });
    }

    const tokenBalance = account.tokenBalance ?? config.loginTokenBalance ?? 20000000;
    const tokenUsed = account.tokenUsed ?? 0;
    const tokenRemaining = Math.max(0, tokenBalance - tokenUsed);

    return jsonResponse(request, 200, {
      verified: true,
      discord_id: discordId,
      user: {
        id: String(account.id),
        name: account.name || '',
        discordId: String(account.discordId || discordId),
        role: account.role || 'user',
        tier: account.tier || config.defaultTier || 'free',
        status: account.status || 'active',
        tokenBalance,
        tokenUsed,
        tokenRemaining,
        creditBalance: account.creditBalance ?? 0,
        tokenResetDays: account.tokenResetDays || config.tokenResetDays || 1,
        lastReset: account.lastReset ?? account.createdAt,
        createdAt: account.createdAt,
      },
      message: 'User terverifikasi dan akun Discord aktif terhubung.',
    });
  }

  // Optional bot endpoint to update user tier: POST /api/bot/sync-tier
  if (pathname === '/api/bot/sync-tier' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const discordId = String(body.discord_id || body.discordId || '').trim();
    const tier = String(body.tier || '').trim();
    if (!discordId || !tier) {
      return jsonResponse(request, 400, { error: 'discord_id and tier are required.' });
    }
    let accountId = await env.PB_KV.get(`link:${discordId}`);
    let account = accountId ? await getJson(env.PB_KV, `account:${accountId}`, null) : null;
    if (!account) {
      return jsonResponse(request, 404, { error: 'Account not found for this discord_id.' });
    }
    account.tier = tier;
    await env.PB_KV.put(`account:${account.id}`, JSON.stringify(account));
    return jsonResponse(request, 200, { ok: true, account });
  }

  // Optional bot endpoint to reward or add tokens: POST /api/bot/add-tokens
  if (pathname === '/api/bot/add-tokens' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const discordId = String(body.discord_id || body.discordId || '').trim();
    const tokens = Number(body.tokens) || 0;
    if (!discordId || tokens <= 0) {
      return jsonResponse(request, 400, { error: 'discord_id and positive tokens number required.' });
    }
    let accountId = await env.PB_KV.get(`link:${discordId}`);
    let account = accountId ? await getJson(env.PB_KV, `account:${accountId}`, null) : null;
    if (!account) {
      return jsonResponse(request, 404, { error: 'Account not found for this discord_id.' });
    }
    account.tokenBalance = (account.tokenBalance ?? 0) + tokens;
    await env.PB_KV.put(`account:${account.id}`, JSON.stringify(account));
    return jsonResponse(request, 200, { ok: true, account });
  }

  return jsonResponse(request, 404, { error: 'Unknown bot endpoint.' });
}

/// Host yang tidak boleh dipakai sebagai target proxy (SSRF): jaringan
/// internal, link-local, metadata cloud, dan loopback selain dev lokal.
function isBlockedProxyHost(hostname) {
  const host = String(hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host === 'metadata.google.internal' || host.endsWith('.internal')) {
    return true;
  }
  if (host === '::1' || host === '0.0.0.0') return true;
  const v4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 10 || a === 127 || a === 0) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
  }
  return false;
}

async function handleCorsProxy(request) {
  const url = new URL(request.url);
  const target = url.searchParams.get('url');
  if (!target) {
    return textResponse(request, 400, 'Missing "url" query parameter.');
  }

  let targetUrl;
  try {
    targetUrl = new URL(target);
  } catch {
    return textResponse(request, 400, 'Invalid target URL.');
  }
  const isLocal =
    targetUrl.hostname === 'localhost' || targetUrl.hostname === '127.0.0.1';
  // A plain-HTTP target would expose the user's API key on the network.
  if (targetUrl.protocol !== 'https:' && !isLocal) {
    return textResponse(request, 400, 'Only HTTPS targets are allowed.');
  }
  // Jangan pernah dipakai untuk menembak jaringan internal / metadata
  // (loopback, link-local, dan LAN ikut ditolak).
  if (isBlockedProxyHost(targetUrl.hostname)) {
    return textResponse(request, 400, 'Target host is not allowed.');
  }
  if (request.method !== 'GET' && request.method !== 'POST') {
    return textResponse(request, 405, 'Method not allowed.');
  }

  // Forward only the headers the API needs. Never forward cookies or the
  // browser's Origin, and never add credentials of your own.
  const headers = new Headers();
  for (const name of ['authorization', 'content-type', 'accept', 'x-secret-key']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  const init = {
    method: request.method,
    headers,
    redirect: 'follow',
    // Batas waktu supaya proxy tidak menggantung.
    signal: AbortSignal.timeout(120000),
  };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = request.body;
  }

  let upstream;
  try {
    upstream = await fetch(targetUrl.toString(), init);
  } catch (error) {
    return textResponse(request, 502, `Upstream request failed: ${error}`);
  }

  const outHeaders = new Headers(corsHeaders(request));
  const contentType = upstream.headers.get('content-type');
  if (contentType) outHeaders.set('Content-Type', contentType);
  outHeaders.set('Cache-Control', 'no-store');

  // Stream the body so SSE token streaming keeps working.
  return new Response(upstream.body, {
    status: upstream.status,
    headers: outHeaders,
  });
}

/// Buang cache daftar model saat server/model berubah, supaya aplikasi
/// langsung melihat data terbaru.
async function invalidateModelCaches(env) {
  try {
    await env.PB_KV.delete('config_models_cache');
    const list = await env.PB_KV.list({ prefix: 'models_cache:' });
    for (const key of list.keys) {
      await env.PB_KV.delete(key.name);
    }
  } catch (_) {
    // Cache bersifat tambahan.
  }
}

// ── API Key Management & Gateway ────────────────────────────────────────

/// Biaya satu sisi (input atau output).
///
/// Kalau admin memberi harga per-request, itu yang dipakai. Kalau tidak,
/// harga per-1M token dikali jumlah token. Harga $0 = pakai kuota token.
function priceSide(perReq, per1M, tokens) {
  if (perReq > 0) return perReq;
  return (per1M * (Number(tokens) || 0)) / 1000000;
}

/// Catat pemakaian (token + credit) ke akun dan ke log pemakaian.
async function chargeUsage(env, account, options) {
  const pricing = options.pricing || {};
  const promptTokens = Number(options.promptTokens) || 0;
  const completionTokens = Number(options.completionTokens) || 0;
  const totalTokens = promptTokens + completionTokens;
  const useCredits = !!options.useCredits;
  const fresh = await getJson(
    env.PB_KV, `account:${account.id}`, account) || account;
  let credits = 0;
  if (useCredits) {
    credits = priceSide(
      Number(pricing.inputPerReq) || 0,
      Number(pricing.inputPer1M) || 0,
      promptTokens,
    ) + priceSide(
      Number(pricing.outputPerReq) || 0,
      Number(pricing.outputPer1M) || 0,
      completionTokens,
    );
    fresh.creditBalance =
      Math.max(0, (Number(fresh.creditBalance) || 0) - credits);
    fresh.creditUsed = (Number(fresh.creditUsed) || 0) + credits;
  } else {
    fresh.tokenUsed = (Number(fresh.tokenUsed) || 0) + totalTokens;
  }
  await env.PB_KV.put(`account:${account.id}`, JSON.stringify(fresh));
  try {
    const logs = await getJson(env.PB_KV, 'usage_logs', []);
    logs.push({
      accountId: account.id,
      accountName: account.name || '',
      modelId: options.modelId || '',
      modelName: options.modelName || options.modelId || '',
      tokens: totalTokens,
      // Kredit bisa sangat kecil (mis. $0.000014) — bulatkan dengan 8
      // desimal supaya tidak jadi 0 di log.
      credits: Math.round(credits * 1e8) / 1e8,
      mode: useCredits ? 'credit' : 'token',
      timestamp: Date.now(),
    });
    if (logs.length > 200) logs.splice(0, logs.length - 200);
    await env.PB_KV.put('usage_logs', JSON.stringify(logs));
  } catch (_) {
    // Log pemakaian tidak boleh menggagalkan request.
  }
  return fresh;
}

async function hashApiKey(key) {
  const encoder = new TextEncoder();
  const data = encoder.encode(key);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

async function handleApiKey(request, env, pathname) {
  const session = await sessionAccount(env, request);
  if (!session) {
    return jsonResponse(request, 401, { error: 'Login required to manage API keys.' });
  }
  const accountId = session.account.id;

  // POST /api/auth/api-key — generate new API key
  if (pathname === '/api/auth/api-key' && request.method === 'POST') {
    const rawKey = `pb_${crypto.randomUUID().replace(/-/g, '')}`;
    const keyHash = await hashApiKey(rawKey);
    const now = Date.now();
    const keyData = {
      accountId,
      hash: keyHash,
      prefix: rawKey.slice(0, 8),
      createdAt: now,
      deleteAt: null,
    };
    await env.PB_KV.put(`apikey:${keyHash}`, JSON.stringify(keyData));
    // Log creation for admin audit
    const logEntry = { accountId, action: 'create', keyPrefix: rawKey.slice(0, 8), timestamp: now };
    const existingLogs = await getJson(env.PB_KV, 'apikey_logs', []);
    existingLogs.push(logEntry);
    if (existingLogs.length > 200) existingLogs.splice(0, existingLogs.length - 200);
    await env.PB_KV.put('apikey_logs', JSON.stringify(existingLogs));
    return jsonResponse(request, 200, { ok: true, apiKey: rawKey, prefix: rawKey.slice(0, 8) });
  }

  // GET /api/auth/api-key — check if user has active key (masked)
  if (pathname === '/api/auth/api-key' && request.method === 'GET') {
    const list = await env.PB_KV.list({ prefix: 'apikey:' });
    for (const k of list.keys) {
      const keyData = await getJson(env.PB_KV, k.name, null);
      if (keyData && keyData.accountId === accountId && !keyData.deleteAt) {
        return jsonResponse(request, 200, {
          hasKey: true,
          prefix: keyData.prefix || 'pb_...',
          createdAt: keyData.createdAt,
        });
      }
    }
    return jsonResponse(request, 200, { hasKey: false });
  }

  // DELETE /api/auth/api-key — mark for deletion (3-day cooldown)
  if (pathname === '/api/auth/api-key' && request.method === 'DELETE') {
    const list = await env.PB_KV.list({ prefix: 'apikey:' });
    for (const k of list.keys) {
      const keyData = await getJson(env.PB_KV, k.name, null);
      if (keyData && keyData.accountId === accountId && !keyData.deleteAt) {
        keyData.deleteAt = Date.now() + 3 * 24 * 60 * 60 * 1000; // 3 days
        await env.PB_KV.put(k.name, JSON.stringify(keyData));
        return jsonResponse(request, 200, {
          ok: true,
          message: 'API key scheduled for deletion in 3 days.',
          deleteAt: keyData.deleteAt,
        });
      }
    }
    return jsonResponse(request, 404, { error: 'No active API key found.' });
  }

  return jsonResponse(request, 404, { error: 'Unknown API key endpoint.' });
}

async function handleGateway(request, env, pathname) {
  // Terima dua bentuk: /api/gateway/... dan /api/gateway/v1/... (OpenAI
  // compatible). Dengan begitu base URL untuk SDK cukup
  // https://<domain>/api/gateway/v1.
  if (pathname.startsWith('/api/gateway/v1')) {
    pathname = '/api/gateway' + pathname.slice('/api/gateway/v1'.length);
  }

  // Authenticate via API key in Authorization: Bearer header
  const authHeader = request.headers.get('authorization') || '';
  const apiKey = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  if (!apiKey) {
    return jsonResponse(request, 401, { error: 'Missing API key. Use Authorization: Bearer <your-api-key>' });
  }

  const keyHash = await hashApiKey(apiKey);
  const keyData = await getJson(env.PB_KV, `apikey:${keyHash}`, null);
  if (!keyData) {
    return jsonResponse(request, 401, { error: 'Invalid API key.' });
  }
  if (keyData.deleteAt && Date.now() >= keyData.deleteAt) {
    await env.PB_KV.delete(`apikey:${keyHash}`);
    return jsonResponse(request, 401, { error: 'API key has been deleted.' });
  }
  if (keyData.deleteAt) {
    return jsonResponse(request, 403, { error: 'API key is pending deletion.', deleteAt: keyData.deleteAt });
  }

  const account = await getJson(env.PB_KV, `account:${keyData.accountId}`, null);
  if (!account) {
    return jsonResponse(request, 401, { error: 'Account not found.' });
  }
  if (account.status === 'banned') {
    return jsonResponse(request, 403, { error: 'Account is banned.' });
  }

  const config = await getConfig(env);

  // GET /api/gateway/models — list models available to this user's tier
  if (pathname === '/api/gateway/models' && request.method === 'GET') {
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const userTier = account.tier || config.defaultTier || 'free';
    const cached = await cachedJson(
      env, `models_cache:${userTier}`, 120, async () => {
        const serverModels = await getJson(env.PB_KV, 'server_models', []);
        const disabled = new Set(
          servers.filter((s) => s.enabled === false).map((s) => String(s.id)));
        const serverById = new Map(
          servers.map((s) => [String(s.id), s]));
        return serverModels
          .filter(m => {
            if (m.serverId && disabled.has(String(m.serverId))) return false;
            const tiers = m.tierAccess || ['free', 'pro', 'vip'];
            return tiers.includes(userTier);
          })
          // Jangan pernah bocorkan API key backend lewat endpoint user.
          .map(({ apiKey, ...rest }) => ({
            ...rest,
            serverName:
              (serverById.get(String(rest.serverId || '')) || {}).name || '',
            serverBaseUrl: rest.apiUrl ||
              (serverById.get(String(rest.serverId || '')) || {}).baseUrl || '',
          }));
      });
    const filtered = cached.value || [];
    return jsonResponse(request, 200, {
      object: 'list',
      data: filtered.map(m => ({
        id: m.modelId,
        object: 'model',
        owned_by: m.serverId || 'piercingblow',
        name: m.name || m.modelId,
      })),
      models: filtered,
      tier: userTier,
      cached: cached.hit,
    });
  }

  // POST /api/gateway/chat/completions — proxy to backend AI server
  if (pathname === '/api/gateway/chat/completions' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }

    const modelId = body.model || '';
    if (!modelId) {
      return jsonResponse(request, 400, { error: 'Missing "model" field.' });
    }

    // Find model config
    const serverModels = await getJson(env.PB_KV, 'server_models', []);
    const modelConfig = serverModels.find(m => m.modelId === modelId);
    if (!modelConfig) {
      return jsonResponse(request, 404, { error: `Model "${modelId}" not found.` });
    }

    // Check tier access
    const userTier = account.tier || config.defaultTier || 'free';
    const allowedTiers = modelConfig.tierAccess || ['free', 'pro', 'vip'];
    if (!allowedTiers.includes(userTier)) {
      return jsonResponse(request, 403, {
        error: `Model "${modelId}" requires tier: ${allowedTiers.join(', ')}. Your tier: ${userTier}`,
      });
    }

    // Check balance.
    //
    // Harga $0 (baik /req maupun /1M) → pemakaian memotong kuota token.
    // Ada harga > 0 → pemakaian memotong credit (tier Pro/VIP).
    const pricing = modelConfig.pricing || {};
    const inputPerReq = Number(pricing.inputPerReq) || 0;
    const outputPerReq = Number(pricing.outputPerReq) || 0;
    const inputPer1M = Number(pricing.inputPer1M) || 0;
    const outputPer1M = Number(pricing.outputPer1M) || 0;
    const useCredits = inputPerReq > 0 || outputPerReq > 0 ||
      inputPer1M > 0 || outputPer1M > 0;

    if (useCredits) {
      // Estimasi minimum: harga per-request kalau ada, selain itu cukup
      // saldo credit > 0 (harga per-1M dihitung setelah usage diketahui).
      const estimatedCost = inputPerReq + outputPerReq;
      const creditBalance = Number(account.creditBalance) || 0;
      if (creditBalance <= 0 || creditBalance < estimatedCost) {
        return jsonResponse(request, 402, {
          error: 'Insufficient credits for this model.',
          required: estimatedCost,
          balance: creditBalance,
        });
      }
    } else {
      if ((Number(account.tokenBalance) || 0) -
        (Number(account.tokenUsed) || 0) <= 0) {
        return jsonResponse(request, 402, {
          error: 'Token quota exhausted. Please refill or upgrade.',
          tokenRemaining: Math.max(
            0,
            (Number(account.tokenBalance) || 0) -
              (Number(account.tokenUsed) || 0),
          ),
        });
      }
    }

    // Proxy to backend server. Model boleh menunjuk server lewat serverId;
    // alamat + API key diambil dari Server manager (KV) kalau kosong.
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const serverConfig = modelConfig.serverId
      ? servers.find((s) => String(s.id) === String(modelConfig.serverId))
      : servers.find((s) =>
        s.baseUrl && s.baseUrl === (modelConfig.serverUrl || modelConfig.apiUrl));
    if (serverConfig && serverConfig.enabled === false) {
      return jsonResponse(request, 403, {
        error: `Server "${serverConfig.id}" sedang dinonaktifkan di dashboard.`,
      });
    }
    const backendUrl = modelConfig.apiUrl || modelConfig.serverUrl ||
      (serverConfig && serverConfig.baseUrl) || '';
    if (!backendUrl) {
      return jsonResponse(request, 503, { error: 'Backend server URL not configured for this model.' });
    }

    const base = backendUrl.replace(/\/+$/, '');
    const targetUrl = /\/v\d+$/i.test(base)
      ? `${base}/chat/completions`
      : `${base}/v1/chat/completions`;

    const headers = new Headers();
    headers.set('Content-Type', 'application/json');
    // Secret inference = manager secret VPS (nginx memakai key yang sama
    // untuk /manager dan /). Entri model lama bisa punya apiKey sendiri.
    const backendKey = modelConfig.apiKey ||
      (serverConfig && (serverConfig.managerKey || serverConfig.apiKey)) || '';
    if (backendKey) {
      // Server Python/nginx memakai header X-Secret-Key. Authorization tetap
      // dikirim untuk backend OpenAI-compatible yang memakainya.
      headers.set('X-Secret-Key', backendKey);
      headers.set('Authorization', `Bearer ${backendKey}`);
    }

    let upstream;
    try {
      const upstreamBody = {
        ...body,
        model: modelConfig.backendModelId || modelId,
      };
      // Minta usage di akhir stream supaya kuota tetap terhitung.
      if (body.stream === true) {
        upstreamBody.stream_options = {
          ...(body.stream_options || {}),
          include_usage: true,
        };
      }
      upstream = await fetch(targetUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(upstreamBody),
      });
    } catch (error) {
      return jsonResponse(request, 502, { error: `Backend request failed: ${error}` });
    }

    // Streaming (SSE) diteruskan apa adanya ke klien. Pemakaian token
    // dibaca dari event `usage`; kalau backend tidak mengirimnya, dipakai
    // perkiraan dari panjang teks.
    if (body.stream === true && upstream.ok && upstream.body) {
      const decoder = new TextDecoder();
      let buffered = '';
      let contentChars = 0;
      let usage = { prompt_tokens: 0, completion_tokens: 0 };
      const tracker = new TransformStream({
        transform(chunk, controller) {
          controller.enqueue(chunk);
          buffered += decoder.decode(chunk, { stream: true });
          let index;
          while ((index = buffered.indexOf('\n')) >= 0) {
            const line = buffered.slice(0, index).trim();
            buffered = buffered.slice(index + 1);
            if (!line.startsWith('data:')) continue;
            const payload = line.slice(5).trim();
            if (!payload || payload === '[DONE]') continue;
            try {
              const parsed = JSON.parse(payload);
              if (parsed && parsed.usage) usage = parsed.usage;
              const choice = parsed && parsed.choices && parsed.choices[0];
              const delta = choice && choice.delta;
              if (delta && typeof delta.content === 'string') {
                contentChars += delta.content.length;
              }
            } catch (_) {
              // Chunk keep-alive / bukan JSON — abaikan.
            }
          }
        },
        async flush(controller) {
          const promptTokens = Number(usage.prompt_tokens) || 0;
          const completionTokens = Number(usage.completion_tokens) ||
            Math.ceil(contentChars / 4);
          if (!promptTokens && !completionTokens) return;
          let credits = 0;
          try {
            const charged = await chargeUsage(env, account, {
              pricing,
              modelId,
              modelName: modelConfig.name || modelId,
              promptTokens,
              completionTokens,
              useCredits,
            });
            credits = useCredits
              ? Math.max(
                  0,
                  (Number(account.creditBalance) || 0) -
                    (Number(charged.creditBalance) || 0),
                )
              : 0;
          } catch (_) {
            // Jangan gagalkan stream hanya karena pencatatan kuota.
          }
          // Header tidak bisa dikirim setelah stream mulai, jadi usage
          // dikirim sebagai satu event SSE terakhir supaya aplikasi bisa
          // langsung menurunkan saldo token/kredit di UI.
          try {
            controller.enqueue(
              new TextEncoder().encode(
                'data: ' + JSON.stringify({
                  piercingblow_usage: true,
                  usage: {
                    prompt_tokens: promptTokens,
                    completion_tokens: completionTokens,
                    total_tokens: promptTokens + completionTokens,
                  },
                  credits: Math.round(credits * 1e8) / 1e8,
                }) + '\n\n',
              ),
            );
          } catch (_) {
            // Stream sudah tertutup — abaikan.
          }
        },
      });
      const streamHeaders = new Headers(corsHeaders(request));
      streamHeaders.set('Content-Type', 'text/event-stream; charset=utf-8');
      streamHeaders.set('Cache-Control', 'no-cache');
      streamHeaders.set('X-Accel-Buffering', 'no');
      return new Response(upstream.body.pipeThrough(tracker), {
        status: upstream.status,
        headers: streamHeaders,
      });
    }

    // Read response to extract usage
    const responseText = await upstream.text();
    let responseData;
    try {
      responseData = JSON.parse(responseText);
    } catch {
      return new Response(responseText, {
        status: upstream.status,
        headers: { ...corsHeaders(request), 'Content-Type': upstream.headers.get('content-type') || 'application/json' },
      });
    }

    // Deduct tokens/credits based on usage
    const usage = responseData.usage || {};
    const promptTokens = usage.prompt_tokens || 0;
    const completionTokens = usage.completion_tokens || 0;
    const totalTokens = promptTokens + completionTokens;

    const charged = await chargeUsage(env, account, {
      pricing,
      modelId,
      modelName: modelConfig.name || modelId,
      promptTokens,
      completionTokens,
      useCredits,
    });
    const creditsUsed = useCredits
      ? Math.max(0, (Number(charged.creditBalance) || 0) -
        (Number(account.creditBalance) || 0))
      : 0;

    return new Response(JSON.stringify(responseData), {
      status: upstream.status,
      headers: {
        ...corsHeaders(request),
        'Content-Type': 'application/json',
        'X-Token-Used': String(totalTokens),
        'X-Credit-Used': String(Math.round(creditsUsed * 10000) / 10000),
      },
    });
  }

  return jsonResponse(request, 404, { error: 'Unknown gateway endpoint.' });
}

async function handleServerModels(request, env, pathname) {
  // Admin-only server models CRUD
  if (!adminAuthorized(request, env)) {
    return jsonResponse(request, 401, { error: 'Invalid admin key.' });
  }

  // GET /api/admin/server-models
  if (pathname === '/api/admin/server-models' && request.method === 'GET') {
    const models = await getJson(env.PB_KV, 'server_models', []);
    return jsonResponse(request, 200, { models });
  }

  // POST /api/admin/server-models — upsert
  if (pathname === '/api/admin/server-models' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    if (!body.modelId) {
      return jsonResponse(request, 400, { error: 'modelId is required.' });
    }
    const models = await getJson(env.PB_KV, 'server_models', []);
    const idx = models.findIndex(m => m.modelId === body.modelId);
    const base = idx >= 0 ? models[idx] : {};
    const entry = {
      modelId: body.modelId,
      // ID asli di server inference dipakai saat proxy chat, supaya modelId
      // publik boleh unik per VPS tanpa mengubah nama model di backend.
      backendModelId: body.backendModelId || base.backendModelId || body.modelId,
      daemonId: body.daemonId || base.daemonId || '',
      name: body.name || base.name || body.modelId,
      serverId: body.serverId || base.serverId || '',
      serverUrl: body.serverUrl || base.serverUrl || '',
      apiUrl: body.apiUrl || base.apiUrl || '',
      apiKey: body.apiKey || base.apiKey || '',
      runtime: body.runtime || base.runtime || '',
      tierAccess: Array.isArray(body.tierAccess)
        ? body.tierAccess
        : (base.tierAccess || ['free', 'pro', 'vip']),
      pricing: body.pricing || base.pricing || {},
      contextSize: body.contextSize ?? base.contextSize ?? 0,
      maxOutput: body.maxOutput ?? base.maxOutput ?? 0,
      detected: body.detected !== undefined
        ? !!body.detected
        : (base.detected !== false),
      createdAt: base.createdAt || Date.now(),
      updatedAt: Date.now(),
    };
    if (idx >= 0) {
      models[idx] = entry;
    } else {
      models.push(entry);
    }
    await env.PB_KV.put('server_models', JSON.stringify(models));
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, { ok: true, model: entry });
  }

  // DELETE /api/admin/server-models/:modelId
  const deleteMatch = pathname.match(/^\/api\/admin\/server-models\/(.+)$/);
  if (deleteMatch && request.method === 'DELETE') {
    const modelId = decodeURIComponent(deleteMatch[1]);
    const models = await getJson(env.PB_KV, 'server_models', []);
    const filtered = models.filter(m => m.modelId !== modelId);
    await env.PB_KV.put('server_models', JSON.stringify(filtered));
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, { ok: true, deleted: modelId });
  }

  // GET /api/admin/api-key-logs
  if (pathname === '/api/admin/api-key-logs' && request.method === 'GET') {
    const logs = await getJson(env.PB_KV, 'apikey_logs', []);
    return jsonResponse(request, 200, { logs: logs.reverse() });
  }

  // GET /api/admin/usage-logs — pemakaian token & credit per request.
  if (pathname === '/api/admin/usage-logs' && request.method === 'GET') {
    const logs = await getJson(env.PB_KV, 'usage_logs', []);
    return jsonResponse(request, 200, { logs: logs.slice().reverse() });
  }

  return jsonResponse(request, 404, { error: 'Unknown server-models endpoint.' });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }
    const url = new URL(request.url);
    const pathname = url.pathname.replace(/\/+$/, '') || '/';

    try {
      // API key per akun untuk gateway (harus dicek sebelum handleAuth umum).
      if (pathname.startsWith('/api/auth/api-key')) {
        return await handleApiKey(request, env, pathname);
      }
      if (pathname.startsWith('/api/auth/')) {
        return await handleAuth(request, env, pathname);
      }
      // Endpoint config server manager & model harga (KV, bukan servers.json).
      if (pathname === '/api/admin/servers' ||
          pathname.startsWith('/api/admin/servers/')) {
        return await handleAdminServers(request, env, pathname);
      }
      if (pathname === '/api/admin/server-models' ||
          pathname.startsWith('/api/admin/server-models/') ||
          pathname === '/api/admin/api-key-logs' ||
          pathname === '/api/admin/usage-logs') {
        return await handleServerModels(request, env, pathname);
      }
      if (pathname.startsWith('/api/admin/')) {
        return await handleAdmin(request, env, pathname);
      }
      if (pathname.startsWith('/api/gateway/')) {
        return await handleGateway(request, env, pathname);
      }
      if (
        pathname.startsWith('/api/bot/') ||
        pathname.startsWith('/api/discord-bot/') ||
        pathname === '/api/discord/verify'
      ) {
        return await handleBotApi(request, env, pathname);
      }
      if (pathname === '/api' || pathname === '/api/') {
        return await handleCorsProxy(request);
      }
      return textResponse(request, 404, 'Not found.');
    } catch (error) {
      return jsonResponse(request, 500, { error: `Worker error: ${error}` });
    }
  },
};