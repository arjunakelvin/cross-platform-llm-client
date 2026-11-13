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
      // untuk tab Model List dan provider Local AI. Alamat internal server
      // (IP VPS / tunnel) tidak ikut publicized.
      const servers = mgrServers
        .filter((s) => s && s.id && s.enabled !== false)
        .map((s) => ({
          id: String(s.id),
          name: String(s.name || s.id),
          // Alamat internal server (IP VPS / tunnel) TIDAK dipublikasikan.
          // Semua request lewat gateway, jadi user tidak perlu alamat itu.
          baseUrl: '',
          runtime: String(s.runtime || ''),
        }));
      const serverById = new Map(servers.map((s) => [s.id, s]));
      const models = serverModels
        .filter((m) => m && m.modelId)
        .filter((m) => m.active !== false)
        .filter((m) => !m.serverId || serverById.has(String(m.serverId)))
        .map((m) => {
          const server = serverById.get(String(m.serverId || ''));
          return {
            // Id publik gateway: `<label>:<model>:<tier>` — bukan nama file.
            modelId: gatewayPublicIdFor(m, mgrServers),
            // Nama model asli di daemon (tanpa folder); dipakai aplikasi saat
            // memanggil server inference langsung (tanpa gateway) sebagai
            // fallback.
            backendModelId: backendModelName(m.backendModelId || m.modelId),
            name: String(m.name || m.modelId),
            serverId: String(m.serverId || ''),
            serverName: server ? server.name : '',
            // Alamat internal server tidak pernah dikirim ke user.
            serverBaseUrl: '',
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
    return jsonResponse(request, 200, {
      ...publicConfig(request, config),
      // Alamat AI server hanya diisi kalau admin menetapkannya sendiri di
      // config — alamat hasil deteksi (IP VPS / tunnel) tidak dipublikasikan.
      aiServerUrl: config.aiServerUrl || '',
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

/// Susun Manager URL dari IP + port daemon (dipakai kalau admin tidak
/// mengisi Manager URL manual, mis. karena daemon ada di belakang nginx).
function buildManagerUrl(body, base) {
  const explicit = String(body.managerUrl ?? base.managerUrl ?? '').trim();
  // URL yang sudah diisi dipakai apa adanya (bisa /manager atau base URL AI).
  if (explicit) return normalizePublicUrl(explicit);
  const host = String(body.ip ?? body.host ?? base.ip ?? base.host ?? '').trim();
  const port = Number(body.port ?? base.port ?? 0);
  if (!host) return '';
  // IP asli → http (VPS lokal/LAN). Hostname (domain / tunnel) → https.
  const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');
  if (isIp && !port) return '';
  const useHttps = !isIp || port === 443;
  const scheme = useHttps ? 'https' : 'http';
  const portPart = (useHttps && (port === 0 || port === 443))
    ? ''
    : `:${port}`;
  return `${scheme}://${host}${portPart}/manager`;
}

function cleanServerEntry(body, existing) {
  const now = Date.now();
  const base = existing || {};
  const keepSecret = (field, value) =>
    typeof value === 'string' && value.trim().length > 0
      ? value.trim()
      : String(base[field] || '');
  const ip = String(body.ip ?? body.host ?? base.ip ?? base.host ?? '').trim();
  const port = Number(body.port ?? base.port ?? 0) || 0;
  // Base URL AI OpenAI-compatible: biasanya diisi dari daemon saat deteksi.
  const baseUrl = normalizePublicUrl(
    body.baseUrl ?? base.baseUrl ?? '').trim();
  return {
    id: cleanServerId(body.id ?? base.id),
    name: String(body.name ?? base.name ?? '').trim(),
    // Satu entri = satu VPS. Admin mengisi IP + port (AI server) + secret
    // key; base URL AI dibuat otomatis, model aktif dideteksi langsung dari
    // AI server (OpenAI-compatible).
    ip,
    port,
    modelFile: String(body.modelFile ?? base.modelFile ?? '').trim(),
    baseUrl,
    // Opsional: kalau daemon manager.py dipakai (start/stop + statistik).
    managerUrl: buildManagerUrl(body, base),
    managerKey: keepSecret('managerKey', body.managerKey),
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

/// Rapikan URL publik dari admin/daemon:
/// - buang skema dobel (`http://https://host` → `https://host`)
/// - tentukan skema kalau belum ada (IP → http, domain → https)
/// - buang port untuk host tunnel Cloudflare: quick tunnel selalu lewat 443,
///   jadi `https://x.trycloudflare.com:8788` berakhir 403/1003.
function normalizePublicUrl(value) {
  let raw = String(value || '').trim();
  if (!raw) return '';
  raw = raw.replace(/^https?:\/\/(?=\s*https?:\/\/)/i, '');
  let scheme = '';
  const match = raw.match(/^(https?):\/\//i);
  if (match) {
    scheme = match[1].toLowerCase();
    raw = raw.slice(match[0].length);
  }
  raw = raw.replace(/\/+$/, '');
  if (!raw) return '';
  const slash = raw.indexOf('/');
  let host = slash >= 0 ? raw.slice(0, slash) : raw;
  const tail = slash >= 0 ? raw.slice(slash) : '';
  const hostname = host.split(':')[0];
  const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(hostname);
  const isTunnel = /\.(trycloudflare\.com|cfargotunnel\.com)$/i.test(hostname);
  if (!scheme) scheme = isIp ? 'http' : 'https';
  if (isTunnel) {
    scheme = 'https';
    host = hostname;
  } else if (scheme === 'https' && /:(80|443)$/.test(host)) {
    host = hostname;
  }
  return `${scheme}://${host}${tail}`;
}

function normalizeManagerUrl(value) {
  let base = normalizePublicUrl(value);
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
    // Hanya model yang AKTIF (AI-nya sudah di-load & prosesnya jalan).
    // Kalau daemon melapor `activeModels`, itu yang dipakai.
    const running = daemon.running === undefined ? true : !!daemon.running;
    let ids = [];
    if (Array.isArray(daemon.activeModels)) {
      ids = daemon.activeModels;
    } else if (running) {
      ids = Array.isArray(daemon.models) ? daemon.models : [];
    }
    // Daemon bisa melaporkan path lengkap (`C:\...\x.gguf`) — ambil nama
    // filenya saja supaya id/model publik tidak berupa path.
    ids = ids
      .map((id) => backendModelName(String(id || '').trim()))
      .filter(Boolean);
    if (!ids.length && running && daemon.model) {
      ids = [backendModelName(String(daemon.model).trim())].filter(Boolean);
    }
    for (const backendId of [...new Set(ids)]) {
      const key = `${daemonId}::${backendId}`;
      if (seen.has(key)) continue;
      seen.add(key);
      detected.push({ backendId, daemonId, apiUrl, runtime });
    }
  }
  return detected;
}

/// Ubah nama file model (`qwen2.5-coder-1.5b-instruct-q4_k_m.gguf`) menjadi
/// nama tampilan yang enak dibaca (`Qwen2.5 Coder 1.5B`), supaya nama file
/// mentah tidak muncul di aplikasi.
function friendlyModelName(raw) {
  const original = String(raw || '').trim();
  if (!original) return '';
  let name = original.split(/[/\\]/).pop() || original;
  name = name.replace(
    /\.(gguf|ggml|litertlm|task|bin|safetensors|onnx|pt|pth)$/i, '');
  name = name.replace(/[-_.](i?q\d+(_[a-z0-9]+)*|f16|f32|bf16)$/i, '');
  name = name.replace(/[-_.](instruct|chat|it|hf)$/i, '');
  // Pemisah kata: dash & underscore. Titik dipertahankan supaya nomor
  // versi tetap utuh ("qwen2.5", "v0.2").
  name = name.replace(/[-_]+/g, ' ').trim();
  if (!name) return original;
  return name
      .split(' ')
      .map((word) => {
        if (!word) return word;
        // "1.5b" → "1.5B", "8b" → "8B"
        if (/^\d/.test(word)) {
          return word.replace(/b$/i, 'B').replace(/m$/i, 'M');
        }
        return word.charAt(0).toUpperCase() + word.slice(1);
      })
      .join(' ');
}

/// Nama model backend tanpa folder. Path di VPS tidak boleh bocor ke user,
/// dan tidak boleh dipakai sebagai id model publik.
function backendModelName(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  // Path absolut Windows (`C:\...\x.gguf`) atau Unix (`/opt/.../x.gguf`).
  const looksLikePath = /^[a-zA-Z]:[\\/]/.test(raw) ||
    raw.includes('\\') || raw.startsWith('/') || raw.startsWith('./');
  // Path relatif juga sering muncul (`llama/model-ai/x.gguf`).
  const hasModelExt = /\.(gguf|ggml|litertlm|task|bin|safetensors|onnx|pt|pth)$/i
    .test(raw);
  if (!looksLikePath && !(hasModelExt && raw.includes('/'))) return raw;
  const parts = raw.split(/[\\/]/).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : raw;
}

/// Slug untuk id model gateway: huruf kecil, angka, titik; pemisah "-".
/// `deepseek-v4.1-flash-q4_k_m.gguf` → `deepseek-v4.1-flash`
function slugifyModelId(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/\.(gguf|ggml|litertlm|task|bin|safetensors|onnx|pt|pth)$/i, '')
    // Buang suffix kuantisasi: q4_k_m, iq2_xs, f16, bf16, dsb.
    .replace(/[-_.](i?q\d+(_[a-z0-9]+)*|f16|f32|bf16)$/i, '')
    // Buang suffix peran yang tidak penting untuk id.
    .replace(/[-_.](instruct|chat|it|hf)$/i, '')
    .replace(/[^a-z0-9.]+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .replace(/-{2,}/g, '-');
}

/// Tag tier di akhir id model: `free`, `pro`, atau `vip`.
function tierTagForAccess(tierAccess) {
  const tiers = Array.isArray(tierAccess)
    ? tierAccess.map((t) => String(t || '').trim().toLowerCase()).filter(Boolean)
    : [];
  if (!tiers.length || tiers.includes('free')) return 'free';
  if (tiers.includes('pro')) return 'pro';
  return tiers[0];
}

/// Samakan tag tier di akhir id turunan (`label:model:tier`) dengan
/// `tierAccess` terbaru dari dashboard. Id kustom yang tidak berakhiran
/// tier dibiarkan apa adanya.
function retagPublicId(modelId, tierAccess) {
  const id = String(modelId || '').trim();
  const match = id.match(/^(.+):(free|pro|vip)$/i);
  if (!match) return id;
  return `${match[1]}:${tierTagForAccess(tierAccess)}`;
}

/// Id model publik untuk `/v1/models` — BUKAN nama/path file.
/// Format: `<label>:<model>:<tier>`, contoh `uncensored:deepseek-v4.1-flash:free`.
/// `label` = nama kustom model di dashboard, kalau tidak ada pakai nama server.
function buildGatewayModelId(options) {
  const opts = options || {};
  // `model` bisa berupa path absolut (`C:\...\x.gguf`) dari data lama KV.
  // Ambil basename dulu supaya id publik tidak pernah memuat folder VPS.
  const modelSlug = slugifyModelId(
    backendModelName(opts.model) || opts.model || opts.label) || 'model';
  const labelSlug = slugifyModelId(opts.label);
  const serverSlug = slugifyModelId(opts.serverName);
  const prefix = (labelSlug && labelSlug !== modelSlug)
    ? labelSlug
    : (serverSlug && serverSlug !== modelSlug ? serverSlug : '');
  const tier = tierTagForAccess(opts.tierAccess);
  return prefix ? `${prefix}:${modelSlug}:${tier}` : `${modelSlug}:${tier}`;
}

/// Id lama yang masih berupa nama/path file harus dibuat ulang.
function looksLikeFilePathId(value) {
  const id = String(value || '').trim();
  if (!id) return true;
  if (/^[a-zA-Z]:[\\/]/.test(id)) return true;
  if (id.includes('\\') || id.includes('/')) return true;
  if (id.startsWith('.')) return true;
  return /\.(gguf|ggml|litertlm|task|bin|safetensors|onnx|pt|pth)$/i.test(id);
}

/// Id yang aman ditampilkan ke user. Id admin yang bukan path dipertahankan;
/// id lama berbentuk file dibuat ulang jadi `<label>:<model>:<tier>`.
function gatewayPublicIdFor(model, servers) {
  const current = String((model && model.modelId) || '').trim();
  const backend = String((model && model.backendModelId) || '');
  const tierAccess = (model && model.tierAccess) || ['free', 'pro', 'vip'];
  if (current && !looksLikeFilePathId(current) && current !== backend) {
    // Id turunan (`…:free`) WAJIB ikut tier terbaru dari dashboard. Tanpa ini,
    // model yang diubah ke PRO/VIP tetap tampil `:free` sampai deteksi ulang.
    return retagPublicId(current, tierAccess);
  }
  const serverId = String((model && model.serverId) || '');
  const server = Array.isArray(servers)
    ? servers.find((s) => String((s && s.id) || '') === serverId)
    : null;
  return buildGatewayModelId({
    label: (model && model.name) || '',
    model: (model && (model.backendModelId || model.modelId)) || '',
    tierAccess,
    serverName: (server && server.name) || serverId,
  });
}

async function syncDetectedModels(env, server, detected, daemons = []) {
  const models = await getJson(env.PB_KV, 'server_models', []);
  const now = Date.now();
  const others = models.filter(
    (m) => String(m.serverId || '') !== String(server.id));
  const existingForServer = models.filter(
    (m) => String(m.serverId || '') === String(server.id));
  const byKey = new Map();
  const byBackend = new Map();
  for (const model of existingForServer) {
    const backend = String(model.backendModelId || model.modelId || '');
    // Index pakai nama backend tanpa folder, supaya entri lama yang masih
    // menyimpan path file tetap ketemu (dan harganya tidak hilang).
    const backendName = backendModelName(backend) || backend;
    const key = `${model.daemonId || ''}::${backendName}`;
    if (!byKey.has(key)) byKey.set(key, model);
    if (backendName && !byBackend.has(backendName)) {
      byBackend.set(backendName, model);
    }
  }
  // Daemon yang masih terdaftar di servers.json (proses ada, cuma mungkin
  // belum jalan). Modelnya tetap disimpan, hanya ditandai tidak aktif.
  const knownDaemons = new Set(
    daemons.map((d) => String((d && d.id) || '')).filter(Boolean));

  const taken = new Set(others.map((m) => String(m.modelId)));
  const added = [];
  const updated = [];
  const kept = [];
  const detectedKeys = new Set();
  for (const item of detected) {
    // Nama backend tanpa folder: `C:\models\x.gguf` → `x.gguf`.
    const backendId = backendModelName(item.backendId);
    if (!backendId) continue;
    const key = `${item.daemonId || ''}::${backendId}`;
    detectedKeys.add(key);
    const existing = byKey.get(key) ||
      // Model yang dibuat manual (tanpa daemonId) tetap cocok lewat nama
      // model backend, supaya harga/tier admin tidak hilang.
      byBackend.get(backendId);
    // Nama tampilan: pakai yang sudah dikustom admin; kalau belum, turunkan
    // dari nama file model supaya `qwen2.5-coder-1.5b-...gguf` tidak muncul
    // mentah-mentah di aplikasi.
    const existingName = String((existing && existing.name) || '').trim();
    const isAutoName = !existingName ||
      existingName === backendId ||
      existingName === String(item.backendId || '') ||
      (existing && existing.modelId === existingName);
    const displayName = isAutoName
      ? friendlyModelName(backendId)
      : existingName;
    const tierAccess = Array.isArray(existing && existing.tierAccess)
      ? existing.tierAccess
      : ['free', 'pro', 'vip'];

    // Id publik gateway: `<label>:<model>:<tier>` mis.
    // `uncensored:deepseek-v4.1-flash:free`. BUKAN path/nama file.
    // Id admin yang sudah bagus dipertahankan; id lama berbentuk file
    // (`x.gguf`, `server1/x.gguf`) dibuat ulang.
    let modelId = String((existing && existing.modelId) || '').trim();
    if (looksLikeFilePathId(modelId) || modelId === backendId) {
      modelId = buildGatewayModelId({
        // Nama kustom admin dipakai sebagai label; kalau nama masih otomatis,
        // pakai nama server (mis. "uncensored") supaya id tidak dobel.
        label: isAutoName ? '' : displayName,
        model: backendId,
        tierAccess,
        serverName: String(server.name || '') || String(server.id || ''),
      });
    } else {
      // Id sudah bagus, tapi tag tier di belakang bisa berubah kalau admin
      // mengubah tier model → sinkronkan tanpa menghapus prefix label.
      modelId = retagPublicId(modelId, tierAccess);
    }
    if (taken.has(modelId)) {
      // Bentrok dengan model di server lain: tambah suffix angka.
      const baseId = modelId;
      let suffix = 2;
      while (taken.has(modelId)) modelId = `${baseId}-${suffix++}`;
    }
    taken.add(modelId);
    const entry = {
      modelId,
      backendModelId: backendId,
      daemonId: item.daemonId || '',
      name: displayName || backendId,
      serverId: String(server.id),
      serverUrl: normalizePublicUrl(item.apiUrl)
        || normalizePublicUrl(server.baseUrl) || '',
      apiUrl: normalizePublicUrl(item.apiUrl) || '',
      runtime: item.runtime || server.runtime || '',
      tierAccess,
      pricing: (existing && existing.pricing) || {},
      contextSize: existing ? (Number(existing.contextSize) || 0) : 0,
      maxOutput: existing ? (Number(existing.maxOutput) || 0) : 0,
      detected: true,
      active: true,
      createdAt: (existing && existing.createdAt) || now,
      updatedAt: now,
    };
    if (existing) updated.push(modelId);
    else added.push(modelId);
    kept.push(entry);
  }

  // Model yang prosesnya masih terdaftar tapi AI-nya belum jalan: tetap
  // disimpan (harga/tier admin tidak hilang), tapi ditandai nonaktif.
  // Kalau deteksi dilakukan langsung ke AI server (tanpa daemon), semua model
  // yang tidak terdeteksi dianggap nonaktif (AI-nya belum jalan).
  const inactive = [];
  for (const model of existingForServer) {
    const backend = String(model.backendModelId || model.modelId || '');
    const backendName = backendModelName(backend) || backend;
    const key = `${model.daemonId || ''}::${backendName}`;
    if (detectedKeys.has(key)) continue;
    if (!daemons.length || knownDaemons.has(String(model.daemonId || ''))) {
      kept.push({ ...model, active: false, updatedAt: now });
      inactive.push(model.modelId);
    }
  }

  // Model dihapus hanya kalau prosesnya benar-benar dihapus dari
  // servers.json (bukan cuma sedang mati).
  const removed = daemons.length ? existingForServer
    .filter((m) => !knownDaemons.has(String(m.daemonId || '')))
    .map((m) => m.modelId) : [];

  await env.PB_KV.put(
    'server_models', JSON.stringify([...others, ...kept]));
  return { added, updated, removed, inactive, total: kept.length };
}

/// Ambil daftar model langsung dari AI server (OpenAI-compatible).
/// dipakai kalau daemon manager.py tidak dipakai.
async function fetchAiModels(base, secret) {
  const clean = String(base || '').trim().replace(/\/+$/, '');
  if (!clean) throw new Error('Base URL AI server belum diisi.');
  const url = /\/v\d+$/.test(clean) ? `${clean}/models` : `${clean}/v1/models`;
  const headers = { Accept: 'application/json' };
  if (secret) {
    headers['X-Secret-Key'] = secret;
    headers.Authorization = `Bearer ${secret}`;
  }
  let res;
  try {
    res = await fetch(url, { headers });
  } catch (error) {
    throw new Error(`Tidak bisa menghubungi ${url}: ${error}`);
  }
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} dari ${url}: ${text.slice(0, 180)}`);
  }
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(`Respons ${url} bukan JSON.`);
  }
  const items = Array.isArray(payload)
    ? payload
    : (Array.isArray(payload && payload.data)
      ? payload.data
      : (Array.isArray(payload && payload.models) ? payload.models : []));
  const ids = items
    .map((item) => {
      if (typeof item === 'string') return item;
      if (item && typeof item === 'object') {
        return item.id || item.name || item.model || '';
      }
      return '';
    })
    .map((id) => String(id || '').trim())
    .filter(Boolean);
  return { ids: [...new Set(ids)], url: clean };
}

/// Tandai model server ini sebagai nonaktif (AI server-nya tidak bisa
/// dihubungi → model dianggap belum dimuat).
async function markServerModelsInactive(env, serverId) {
  const models = await getJson(env.PB_KV, 'server_models', []);
  let changed = false;
  for (const model of models) {
    if (String(model.serverId || '') === String(serverId) &&
      model.active !== false) {
      model.active = false;
      changed = true;
    }
  }
  if (changed) {
    await env.PB_KV.put('server_models', JSON.stringify(models));
    await invalidateModelCaches(env);
  }
}

async function detectViaManager(env, server) {
  const raw = normalizePublicUrl(server.managerUrl);
  if (!raw) throw new Error('Base URL AI server belum diisi.');

  // URL yang berakhiran /manager → flow lama (daemon manager.py).
  if (/\/manager\/?$/i.test(raw)) {
    try {
      const daemons = await fetchManagerServers(server);
      const detected = detectedModelsFromManager(daemons);
      const first = daemons.find((d) => d && (d.runtime || d.apiUrl)) || {};
      if (first.runtime) server.runtime = String(first.runtime);
      if (first.apiUrl) server.baseUrl = normalizePublicUrl(first.apiUrl);
      const sync = await syncDetectedModels(env, server, detected, daemons);
      return {
        ok: true,
        count: detected.length,
        daemons: daemons.length,
        activeDaemons: daemons.filter((d) => d && d.running).length,
        ...sync,
        // Id publik yang sekarang dipakai gateway (bukan nama file).
        models: [...sync.added, ...sync.updated],
      };
    } catch (error) {
      // Lanjut ke deteksi langsung ke AI server.
      console.log('[worker] daemon tidak bisa dibaca:', error && error.message);
    }
  }

  // Alur biasa: tanya langsung AI server (OpenAI-compatible).
  // Kalau URL-nya /manager tapi daemonnya tidak ada → coba AI server di
  // host:port yang sama (port AI server), jadi dashboard tetap cukup
  // IP + port + secret key.
  let target = raw;
  if (/\/manager\/?$/i.test(target)) {
    target = target.replace(/\/manager\/?$/i, '');
  }
  const { ids, url } = await fetchAiModels(target, server.managerKey);
  server.baseUrl = url;
  const detected = ids.map((id) => ({
    backendId: backendModelName(id),
    daemonId: '',
    apiUrl: url,
    runtime: server.runtime || '',
  }));
  const sync = await syncDetectedModels(env, server, detected, []);
  return {
    ok: true,
    count: detected.length,
    daemons: 0,
    activeDaemons: ids.length ? 1 : 0,
    ...sync,
    models: [...sync.added, ...sync.updated],
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
      return jsonResponse(request, 400, {
        error: 'IP + port daemon wajib diisi (atau isi Manager URL manual).',
      });
    }
    // Deteksi model: langsung ke AI server (atau daemon manager.py).
    let detection = { ok: false, skipped: true, count: 0, models: [] };
    try {
      detection = await detectViaManager(env, entry);
    } catch (error) {
      // AI server tidak bisa dihubungi → model-nya dianggap belum aktif.
      await markServerModelsInactive(env, entry.id);
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
      // AI server tidak bisa dihubungi → model-nya dianggap belum aktif.
      await markServerModelsInactive(env, server.id);
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

/// Host yang TIDAK boleh jadi target proxy: endpoint metadata cloud
/// (AWS/GCP/Azure) yang bisa dipakai mencuri kredensial instance.
/// IP private lain tetap boleh — AI server user sering ada di jaringan
/// lokal (192.168.x, 10.x, atau 127.0.0.1).
function isBlockedProxyHost(hostname) {
  const host = String(hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
  if (!host) return true;
  if (host === '169.254.169.254') return true;
  if (host === '100.100.100.200') return true;
  if (host === 'metadata.google.internal' || host === 'metadata.goog') {
    return true;
  }
  if (host === 'fd00:ec2::254') return true;
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
      // Hanya SATU yang terisi, sesuai mode pakai:
      //   mode token  → jumlah token
      //   mode credit → jumlah kredit
      // Jadi kolom log tidak pernah mencampur token & kredit.
      tokens: useCredits ? 0 : totalTokens,
      credits: useCredits ? Math.round(credits * 1e8) / 1e8 : 0,
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
  const account = session.account;
  const accountId = account.id;

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
    const logEntry = {
      id: crypto.randomUUID(),
      accountId,
      accountName: account.name || '',
      action: 'create',
      keyPrefix: rawKey.slice(0, 8),
      timestamp: now,
    };
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

  // Authenticate via API key in Authorization: Bearer header.
  // Fallback: session token login (dipakai aplikasi web supaya Local AI
  // tetap bisa lewat gateway sebelum user membuat AI API key sendiri).
  const authHeader = request.headers.get('authorization') || '';
  const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  if (!bearer) {
    return jsonResponse(request, 401, { error: 'Missing API key. Use Authorization: Bearer <your-api-key>' });
  }

  let account = null;
  const keyHash = await hashApiKey(bearer);
  const keyData = await getJson(env.PB_KV, `apikey:${keyHash}`, null);
  if (keyData) {
    if (keyData.deleteAt && Date.now() >= keyData.deleteAt) {
      await env.PB_KV.delete(`apikey:${keyHash}`);
      return jsonResponse(request, 401, { error: 'API key has been deleted.' });
    }
    if (keyData.deleteAt) {
      return jsonResponse(request, 403, { error: 'API key is pending deletion.', deleteAt: keyData.deleteAt });
    }
    account = await getJson(env.PB_KV, `account:${keyData.accountId}`, null);
  } else {
    // Bukan API key → coba session token.
    // Nilai session di KV disimpan sebagai string accountId (bukan JSON).
    const sessionAccountId = await env.PB_KV.get(`session:${bearer}`);
    if (sessionAccountId) {
      account = await getJson(env.PB_KV, `account:${sessionAccountId}`, null);
    }
  }
  if (!account) {
    return jsonResponse(request, 401, { error: 'Invalid API key.' });
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
            // Model yang AI-nya belum dimuat tidak ditawarkan ke user.
            if (m.active === false) return false;
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
    // Id publik tidak pernah berupa nama/path file. Entri lama yang belum
    // di-sync ulang tetap ditampilkan dengan id `<label>:<model>:<tier>`.
    const withPublicId = filtered.map((m) => ({
      ...m,
      modelId: gatewayPublicIdFor(m, servers),
      backendModelId: backendModelName(m.backendModelId || m.modelId),
    }));
    return jsonResponse(request, 200, {
      object: 'list',
      data: withPublicId.map(m => ({
        id: m.modelId,
        object: 'model',
        owned_by: m.serverId || 'piercingblow',
        name: m.name || m.modelId,
        tier: tierTagForAccess(m.tierAccess),
      })),
      models: withPublicId,
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

    // Model dikirim sebagai id publik (`uncensored:deepseek-v4.1-flash:free`).
    // Tetap terima id lama (nama file / backend id) supaya klien lama jalan.
    const wantedModel = String(body.model || '').trim();
    if (!wantedModel) {
      return jsonResponse(request, 400, { error: 'Missing "model" field.' });
    }

    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    const serverModels = await getJson(env.PB_KV, 'server_models', []);
    const wantedBackend = backendModelName(wantedModel);
    const modelConfig =
      serverModels.find((m) => String(m.modelId) === wantedModel) ||
      serverModels.find((m) =>
        backendModelName(m.backendModelId || m.modelId) === wantedBackend) ||
      serverModels.find((m) =>
        gatewayPublicIdFor(m, servers) === wantedModel);
    if (!modelConfig) {
      return jsonResponse(request, 404, {
        error: `Model "${wantedModel}" not found.`,
      });
    }
    const modelId = String(modelConfig.modelId);

    // Check tier access
    // FREE model → bisa dipakai siapa saja (token/credit sesuai label model),
    // tanpa restriction tier. MODEL PRO/VIP → cek tier user.
    const userTier = account.tier || config.defaultTier || 'free';
    const allowedTiers = modelConfig.tierAccess || ['free', 'pro', 'vip'];
    const isFreeModel = allowedTiers.includes('free');
    if (isFreeModel) {
      // Model FREE → semua tier boleh gunakan (tanpa restriction).
      // Pembagian token/credit akan diatur berdasarkan label model di bawah.
    } else if (!allowedTiers.includes(userTier)) {
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
    // Aturan tagihan berdasarkan LABEL model (bukan tier user):
    // FREE model  → selalu potong token dari kuota user
    // PRO/VIP model → potongan kredit, TAPI jika user tier VIP/kredit-habis,
    //               maka jatuhkan ke mode token (bukan paksa pakai model premium
    //               tanpa uang). Ini supaya user tetap bisa pakai model mahal jika
    //               kredit habis, dengan cara turun ke token.
    // Catatan: `isFreeModel` sudah dihitung di atas dari `allowedTiers`
    // (dipakai juga untuk cek akses tier), jadi JANGAN deklarasikan ulang —
    // `const` ganda dalam satu scope = SyntaxError dan worker gagal load.

    // Jika model FREE → selalu pakai token (tanpa memperhatikan tier user).
    // Jika model PRO/VIP → cek kredit user.
    //   - Jika punya kredit → potong kredit.
    //   - Jika TIDAK punya kredit (balance <= 0) → turun ke mode token
    //     supaya user tetap bisa request (bukan error 402).
    let useCredits;
    if (isFreeModel) {
      // MODEL FREE → selalu token.
      useCredits = false;
    } else {
      // MODEL PRO/VIP.
      const creditBalance = Number(account.creditBalance) || 0;
      // Jika user punya credit > 0 → pakai kredit.
      // Jika user kredit habis (balance <= 0) → turun ke token agar bisa jalan.
      useCredits = creditBalance > 0;
    }

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
    // `servers` sudah dibaca di atas saat mencari model.
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
        // Backend selalu menerima nama model asli (bukan id publik
        // `label:model:tier`) dan tanpa folder path.
        model: backendModelName(modelConfig.backendModelId || modelId),
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
                  // Mode menentukan mana yang dipotong: token ATAU kredit.
                  mode: useCredits ? 'credit' : 'token',
                  // Mode credit → JANGAN kirim token (biar app tidak ikut
                  // memotong kuota token). Mode token → tanpa kredit.
                  usage: useCredits
                    ? null
                    : {
                        prompt_tokens: promptTokens,
                        completion_tokens: completionTokens,
                        total_tokens: promptTokens + completionTokens,
                      },
                  credits: useCredits
                    ? Math.round(credits * 1e8) / 1e8
                    : 0,
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
    // Kredit terpakai = saldo sebelum - saldo sesudah (jangan dibalik).
    const creditsUsed = useCredits
      ? Math.max(0, (Number(account.creditBalance) || 0) -
        (Number(charged.creditBalance) || 0))
      : 0;

    return new Response(JSON.stringify(responseData), {
      status: upstream.status,
      headers: {
        ...corsHeaders(request),
        'Content-Type': 'application/json',
        // Mode credit → token TIDAK dipotong, jadi header token harus 0.
        // Mode token  → kredit tidak dipotong.
        'X-Token-Used': String(useCredits ? 0 : totalTokens),
        'X-Credit-Used': String(Math.round(creditsUsed * 1e8) / 1e8),
        'X-Usage-Mode': useCredits ? 'credit' : 'token',
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
    const stored = await getJson(env.PB_KV, 'server_models', []);
    const servers = await getJson(env.PB_KV, 'mgr_servers', []);
    // Rapikan id turunan yang tag tier-nya masih lama (`…:free`) supaya sama
    // dengan tier yang disimpan di dashboard. Sekali jalan, lalu simpan lagi.
    let changed = false;
    const models = stored.map((m) => {
      const fixed = retagPublicId(m.modelId, m.tierAccess);
      if (fixed && fixed !== m.modelId) {
        changed = true;
        return { ...m, modelId: fixed };
      }
      return m;
    });
    if (changed) {
      await env.PB_KV.put('server_models', JSON.stringify(models));
      await invalidateModelCaches(env);
    }
    // `publicId` = id yang dipakai client ke gateway (`label:model:tier`).
    // `modelId` tetap dikirim apa adanya karena dipakai sebagai kunci edit.
    return jsonResponse(request, 200, {
      models: models.map((m) => ({
        ...m,
        publicId: gatewayPublicIdFor(m, servers),
      })),
    });
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
    const submittedId = String(body.modelId).trim();
    // Cari entri lama lewat id yang dikirim. Kalau modal mengirim id yang
    // sudah di-retag (…:pro) sementara KV masih …:free, cocokkan lewat
    // retag agar tidak membuat entri duplikat.
    let idx = models.findIndex(m => m.modelId === submittedId);
    if (idx < 0) {
      idx = models.findIndex(
        (m) => retagPublicId(m.modelId, m.tierAccess) === submittedId);
    }
    const base = idx >= 0 ? models[idx] : {};
    const tierAccess = Array.isArray(body.tierAccess)
      ? body.tierAccess
      : (base.tierAccess || ['free', 'pro', 'vip']);
    // Simpan id dengan tag tier yang sesuai pilihan dashboard, bukan tag
    // lama yang sudah tidak cocok.
    const finalModelId = retagPublicId(submittedId, tierAccess) || submittedId;
    const entry = {
      modelId: finalModelId,
      // ID asli di server inference dipakai saat proxy chat, supaya modelId
      // publik boleh unik per VPS tanpa mengubah nama model di backend.
      backendModelId: backendModelName(
        body.backendModelId || base.backendModelId || body.modelId),
      daemonId: body.daemonId || base.daemonId || '',
      name: body.name || base.name || body.modelId,
      serverId: body.serverId || base.serverId || '',
      serverUrl: body.serverUrl || base.serverUrl || '',
      apiUrl: body.apiUrl || base.apiUrl || '',
      apiKey: body.apiKey || base.apiKey || '',
      runtime: body.runtime || base.runtime || '',
      tierAccess,
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
    return jsonResponse(request, 200, { logs: logs.slice().reverse() });
  }

  // DELETE /api/admin/api-key-logs — hapus satu entri (body {id}) atau
  // semua entri kalau body {all: true} / tanpa id.
  if (pathname === '/api/admin/api-key-logs' && request.method === 'DELETE') {
    let body = {};
    try {
      body = await request.json();
    } catch {
      body = {};
    }
    const logs = await getJson(env.PB_KV, 'apikey_logs', []);
    const id = body && body.id ? String(body.id) : '';
    let next = logs;
    if (id) {
      next = logs.filter((l) => String(l.id || '') !== id);
    } else if (body && body.all) {
      next = [];
    } else {
      return jsonResponse(request, 400, {
        error: 'Sebutkan id log yang mau dihapus (atau all: true).',
      });
    }
    await env.PB_KV.put('apikey_logs', JSON.stringify(next));
    return jsonResponse(request, 200, {
      ok: true,
      removed: logs.length - next.length,
    });
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