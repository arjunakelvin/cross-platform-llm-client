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

// Batas request harian bawaan **per akun**. Admin bisa mengubah angka ini di
// dashboard (Tier & kuota). Nilai 0 / kosong tetap memakai default ini supaya
// setiap akun punya jatah yang jelas — bukan tanpa batas.
const DEFAULT_DAILY_REQUEST_LIMIT = 20;

// Batas request harian otomatis untuk akun tier **free**.
const FREE_DAILY_REQUEST_LIMIT = 15;

// Batas request harian otomatis untuk akun **guest** (tanpa login Discord).
// Setelah guest kehabisan 5 request/hari, dia harus login kembali untuk
// mendapat jatah baru (reset counter UTC tengah malam tetap berlaku).
const GUEST_DAILY_REQUEST_LIMIT = 5;

// ─────────────────────────────────────────────────────────────
// Plan berbayar (credit pack + membership VIP/Pro). Diatur admin di
// dashboard (Plans). User membayar manual ke wallet ShopeePay/GoPay
// admin lalu mengunggah bukti; admin approve di dashboard → kredit /
// token / tier otomatis masuk ke akun.
// ─────────────────────────────────────────────────────────────
// Durasi membership VIP/Pro (hari). Diatur admin per akun di dashboard.
const PLAN_MEMBERSHIP_DURATION_DAYS = 30;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

const PLAN_KINDS = ['credit', 'membership'];
const PLAN_TIERS = ['none', 'vip', 'pro'];
const WALLET_TYPES = ['shopeepay', 'gopay'];

const DEFAULT_PLANS = [
  { id: 'credit-starter', kind: 'credit', name: 'Starter', priceIdr: 50000,
    credits: 5, tokenBonus: 5000000, tier: 'none', dailyReqLimit: 0,
    description: '$5 kredit + 5M token bonus', active: true, sort: 1 },
  { id: 'credit-popular', kind: 'credit', name: 'Popular', priceIdr: 100000,
    credits: 12, tokenBonus: 15000000, tier: 'none', dailyReqLimit: 0,
    description: '$12 kredit + 15M token bonus', active: true, sort: 2 },
  { id: 'credit-best', kind: 'credit', name: 'Best Value', priceIdr: 250000,
    credits: 30, tokenBonus: 50000000, tier: 'none', dailyReqLimit: 0,
    description: '$30 kredit + 50M token bonus', active: true, sort: 3 },
  { id: 'membership-vip', kind: 'membership', name: 'VIP', priceIdr: 150000,
    credits: 2, tokenBonus: 10000000, tier: 'vip', dailyReqLimit: 30,
    durationDays: PLAN_MEMBERSHIP_DURATION_DAYS,
    description: 'Membership VIP 30 hari — tier VIP, +30 req/hari, $2 kredit + 10M token',
    active: true, sort: 4 },
  { id: 'membership-pro', kind: 'membership', name: 'PRO', priceIdr: 300000,
    credits: 5, tokenBonus: 20000000, tier: 'pro', dailyReqLimit: 45,
    durationDays: PLAN_MEMBERSHIP_DURATION_DAYS,
    description: 'Membership PRO 30 hari — tier PRO, +45 req/hari, $5 kredit + 20M token',
    active: true, sort: 5 },
];

const DEFAULT_WALLETS = [
  { id: 'shopeepay-1', type: 'shopeepay', label: 'ShopeePay',
    account: '', note: '', active: true },
  { id: 'gopay-1', type: 'gopay', label: 'GoPay',
    account: '', note: '', active: true },
];

function cleanPlan(input, fallbackId) {
  const src = input && typeof input === 'object' ? input : {};
  const tier = String(src.tier || 'none').trim().toLowerCase();
  const kind = String(src.kind || 'credit').trim().toLowerCase();
  const name = String(src.name || '').trim().slice(0, 80);
  const description = String(src.description || '').trim().slice(0, 160);
  if (!name) return null;
  const id = String(src.id || fallbackId || '').trim().slice(0, 64);
  if (!id) return null;
  const isMembership = PLAN_KINDS.includes(kind) && kind === 'membership';
  const durationDays = Math.max(0,
    Math.floor(Number(src.durationDays) || (isMembership ? PLAN_MEMBERSHIP_DURATION_DAYS : 0)));
  return {
    id,
    kind: PLAN_KINDS.includes(kind) ? kind : 'credit',
    name,
    priceIdr: Math.max(0, Math.floor(Number(src.priceIdr) || 0)),
    credits: Math.max(0, Number(src.credits) || 0),
    tokenBonus: Math.max(0, Math.floor(Number(src.tokenBonus) || 0)),
    tier: PLAN_TIERS.includes(tier) ? tier : 'none',
    dailyReqLimit: Math.max(0, Math.floor(Number(src.dailyReqLimit) || 0)),
    durationDays,
    description,
    active: src.active !== false,
    sort: Math.floor(Number(src.sort) || 0),
  };
}

function cleanWallet(input, fallbackId) {
  const src = input && typeof input === 'object' ? input : {};
  const type = String(src.type || '').trim().toLowerCase();
  if (!WALLET_TYPES.includes(type)) return null;
  const account = String(src.account || '').trim().slice(0, 64);
  if (!account) return null;
  return {
    id: String(src.id || fallbackId || '').trim().slice(0, 64) ||
        `${type}-${Date.now().toString(36)}`,
    type,
    label: String(src.label || (type === 'shopeepay' ? 'ShopeePay' : 'GoPay'))
      .trim().slice(0, 40),
    account,
    note: String(src.note || '').trim().slice(0, 160),
    active: src.active !== false,
  };
}

async function getPlans(env) {
  const stored = await getJson(env.PB_KV, 'plans', null);
  if (!Array.isArray(stored) || stored.length === 0) {
    // Seed default sekali supaya dashboard langsung menampilkan paket.
    await env.PB_KV.put('plans', JSON.stringify(DEFAULT_PLANS));
    return DEFAULT_PLANS.map((p) => ({ ...p }));
  }
  const cleaned = [];
  const seen = new Set();
  for (let i = 0; i < stored.length && cleaned.length < 50; i++) {
    const plan = cleanPlan(stored[i], `plan-${i}`);
    if (!plan || seen.has(plan.id)) continue;
    seen.add(plan.id);
    cleaned.push(plan);
  }
  return cleaned;
}

async function getWallets(env) {
  const stored = await getJson(env.PB_KV, 'payment_wallets', null);
  if (!Array.isArray(stored) || stored.length === 0) {
    await env.PB_KV.put('payment_wallets', JSON.stringify(DEFAULT_WALLETS));
    return DEFAULT_WALLETS.map((w) => ({ ...w }));
  }
  const cleaned = [];
  for (let i = 0; i < stored.length && cleaned.length < 20; i++) {
    const wallet = cleanWallet(stored[i], `wallet-${i}`);
    if (wallet) cleaned.push(wallet);
  }
  return cleaned;
}

async function getPlanOrders(env) {
  const stored = await getJson(env.PB_KV, 'plan_orders', []);
  return Array.isArray(stored) ? stored : [];
}

async function savePlanOrders(env, orders) {
  // Simpan paling banyak 200 pesanan terakhir.
  await env.PB_KV.put('plan_orders', JSON.stringify(orders.slice(0, 200)));
}

const DEFAULT_CONFIG = {
  discord: { enabled: false, clientId: '', clientSecret: '', redirectUri: '' },
  tiers: ['free', 'pro', 'vip'],
  defaultTier: 'free',
  guestTokenBalance: 10000000, // 10M tanpa login
  loginTokenBalance: 20000000, // 20M setelah login Discord (10M + bonus 10M)
  tokenResetDays: 1, // durasi reset token (hari), bisa diubah di dashboard
  // Batas request per akun per hari untuk SEMUA model gateway (default 20).
  // Bisa dioverride per provider API eksternal lewat limit model.
  dailyRequestLimit: DEFAULT_DAILY_REQUEST_LIMIT,
  botSecretKey: '', // optional secret for Discord bot API verification
  aiServerUrl: '',
  localCloudKey: '',
  // Server Manager (lihat server/README.md): alamat API manager + secret
  // yang dipakai web client untuk start/stop server AI.
  managerUrl: '',
  managerSecretKey: '',
  // System prompt global dari dashboard admin. Kosong = aplikasi memakai
  // prompt bawaannya sendiri (model uncensored punya prompt khusus).
  systemPrompt: '',
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
    // Statistik per model (prompt cache) supaya kelihatan model mana yang
    // sering dipakai dan berapa hit/miss-nya.
    models: await modelCacheStats(env),
  };
}

// ── Statistik prompt cache per model ─────────────────────────────────────
// llama-server melaporkan `timings.cache_n` (token prompt yang dipakai ulang
// dari cache KV) dan `timings.prompt_n` (token yang benar-benar diproses).
// Angka itu dicatat per model supaya admin/user tahu model mana yang sering
// dipakai dan seberapa efektif cache-nya — bukan cuma satu angka global.

const MODEL_STATS_KEY = 'model_stats';
const MODEL_STATS_MAX = 200;

function emptyModelStat() {
  return {
    requests: 0,
    hits: 0,
    misses: 0,
    promptTokens: 0,
    cachedTokens: 0,
    completionTokens: 0,
    tokensPerSec: 0,
    lastUsedAt: 0,
    // Riwayat per jam (`YYYY-MM-DDTHH` → {hits, misses}) untuk grafik cache
    // rate di Model List aplikasi.
    hours: {},
  };
}

/// Catat satu request selesai untuk sebuah model.
async function recordModelUsage(env, modelId, sample = {}) {
  const id = String(modelId || '').trim();
  if (!id) return;
  try {
    const stats = await getJson(env.PB_KV, MODEL_STATS_KEY, {});
    const entry = stats[id] || emptyModelStat();
    const promptTokens = Math.max(0, Number(sample.promptTokens) || 0);
    const cachedTokens = Math.max(0, Number(sample.cachedTokens) || 0);
    entry.requests = (Number(entry.requests) || 0) + 1;
    entry.promptTokens = (Number(entry.promptTokens) || 0) + promptTokens;
    entry.cachedTokens = (Number(entry.cachedTokens) || 0) + cachedTokens;
    entry.completionTokens = (Number(entry.completionTokens) || 0) +
      Math.max(0, Number(sample.completionTokens) || 0);
    // Kecepatan terbaru (tok/s) yang dilaporkan server untuk model ini.
    entry.tokensPerSec = Number(sample.tokensPerSec) || 0;
    // Hit = prompt-nya sebagian/utuh dipakai ulang dari cache. Kalau backend
    // tidak melaporkan jumlah token, request tetap dihitung tapi tidak
    // mengubah rasio hit/miss.
    const judged = promptTokens > 0;
    const hit = judged && cachedTokens > 0;
    if (judged) {
      if (hit) entry.hits = (Number(entry.hits) || 0) + 1;
      else entry.misses = (Number(entry.misses) || 0) + 1;
    }
    entry.lastUsedAt = Date.now();
    // Riwayat 48 jam terakhir untuk grafik: hit/miss per jam.
    if (judged) {
      const hour = new Date().toISOString().slice(0, 13);
      const buckets = (entry.hours && typeof entry.hours === 'object')
        ? entry.hours
        : {};
      const bucket = buckets[hour] || { hits: 0, misses: 0 };
      if (hit) bucket.hits = (Number(bucket.hits) || 0) + 1;
      else bucket.misses = (Number(bucket.misses) || 0) + 1;
      buckets[hour] = bucket;
      const keys = Object.keys(buckets).sort();
      while (keys.length > 48) delete buckets[keys.shift()];
      entry.hours = buckets;
    }
    stats[id] = entry;
    // Jaga ukuran KV: simpan hanya model yang paling baru dipakai.
    const ids = Object.keys(stats);
    if (ids.length > MODEL_STATS_MAX) {
      ids.sort((a, b) =>
        (Number(stats[a].lastUsedAt) || 0) - (Number(stats[b].lastUsedAt) || 0));
      for (const old of ids.slice(0, ids.length - MODEL_STATS_MAX)) {
        delete stats[old];
      }
    }
    await env.PB_KV.put(MODEL_STATS_KEY, JSON.stringify(stats));
  } catch (_) {
    // Statistik tidak boleh menggagalkan request.
  }
}

/// Riwayat cache 24 jam terakhir untuk satu model: hit/miss per jam + rasio.
/// Model yang belum pernah dipakai tetap mengembalikan 24 bucket kosong supaya
/// grafik di aplikasi punya bentuk yang stabil.
function modelHourlyCache(rawHours) {
  const buckets = (rawHours && typeof rawHours === 'object') ? rawHours : {};
  const now = Date.now();
  const rows = [];
  for (let i = 23; i >= 0; i--) {
    const date = new Date(now - i * 60 * 60 * 1000);
    const key = date.toISOString().slice(0, 13);
    const bucket = buckets[key] || { hits: 0, misses: 0 };
    const hits = Number(bucket.hits) || 0;
    const misses = Number(bucket.misses) || 0;
    const total = hits + misses;
    rows.push({
      hour: `${key.slice(11)}:00`,
      hits,
      misses,
      hitRate: total > 0 ? Math.round((hits / total) * 1000) / 10 : 0,
    });
  }
  return rows;
}

/// Ringkasan cache/pemakaian per model, digabung dengan daftar model supaya
/// model yang belum pernah dipakai tetap muncul (dengan angka 0).
async function modelCacheStats(env) {
  const [stats, models] = await Promise.all([
    getJson(env.PB_KV, MODEL_STATS_KEY, {}),
    getJson(env.PB_KV, 'server_models', []),
  ]);
  const nameById = new Map();
  for (const model of models) {
    const id = String(model.modelId || '');
    if (id) nameById.set(id, String(model.name || id));
  }
  const ids = new Set([...Object.keys(stats), ...nameById.keys()]);
  const rows = [];
  for (const id of ids) {
    const raw = stats[id] || emptyModelStat();
    const hits = Number(raw.hits) || 0;
    const misses = Number(raw.misses) || 0;
    const judged = hits + misses;
    rows.push({
      modelId: id,
      name: nameById.get(id) || id,
      requests: Number(raw.requests) || 0,
      hits,
      misses,
      // Rasio dihitung dari request yang punya data token, bukan dari
      // total request (backend lama tidak melaporkan cache).
      hitRate: judged > 0 ? Math.round((hits / judged) * 1000) / 10 : 0,
      promptTokens: Number(raw.promptTokens) || 0,
      cachedTokens: Number(raw.cachedTokens) || 0,
      completionTokens: Number(raw.completionTokens) || 0,
      tokensPerSec: Number(raw.tokensPerSec) || 0,
      lastUsedAt: Number(raw.lastUsedAt) || 0,
      // Grafik cache rate 24 jam terakhir (hit/miss per jam).
      hours: modelHourlyCache(raw.hours),
    });
  }
  rows.sort((a, b) =>
    (b.lastUsedAt - a.lastUsedAt) || (b.requests - a.requests) ||
    a.name.localeCompare(b.name));
  return rows;
}

// ── Provider API eksternal ───────────────────────────────────────────────
// Admin cukup mengisi base URL + API key (mis. Cloudflare Workers AI).
// Model provider tampil di aplikasi sebagai `api:<id>` dan request-nya
// diproksi lewat gateway, jadi API key tidak pernah dikirim ke user.
const API_PROVIDERS_KEY = 'api_providers';

function apiProviderPublicId(provider, model, total) {
  // Data KV format lama (satu `model` di level provider) memakai id pendek
  // `api:<id>` supaya klien lama tetap jalan. Provider baru dengan daftar
  // `models` selalu memakai `api:<id>:<key>` agar setiap model unik.
  const list = Array.isArray(provider.models)
    ? provider.models.filter((m) => m && m.modelId)
    : [];
  const legacySingle = list.length === 1 && list[0].key === 'default';
  if (!list.length || legacySingle) return `api:${provider.id}`;
  return `api:${provider.id}:${model.key}`;
}

function slugProviderId(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
}

function slugModelKey(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/^@cf\//, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
}

function cleanPricing(raw, fallback) {
  const source = (raw && typeof raw === 'object')
    ? raw
    : (fallback && typeof fallback === 'object' ? fallback : {});
  const pricing = {};
  for (const key of ['inputPerReq', 'outputPerReq', 'inputPer1M',
    'outputPer1M']) {
    const value = Number(source[key]) || 0;
    if (value > 0) pricing[key] = value;
  }
  return pricing;
}

/// Satu model di dalam provider. Admin bisa mengatur context, max output,
/// limit harian, harga, dan on/off per model.
function cleanProviderModel(raw, index, defaults) {
  const source = typeof raw === 'string' ? { modelId: raw } : (raw || {});
  const modelId = String(source.modelId ?? source.model ?? '').trim();
  const name = String(source.name ?? '').trim() || modelId;
  return {
    key: slugModelKey(source.key || name || modelId) || `model-${index + 1}`,
    modelId,
    name,
    contextSize: Math.max(0,
      Number(source.contextSize ?? defaults.contextSize ?? 0) || 0),
    maxOutput: Math.max(0,
      Number(source.maxOutput ?? defaults.maxOutput ?? 0) || 0),
    dailyRequestLimit: Math.max(0, Math.floor(
      Number(source.dailyRequestLimit ?? defaults.dailyRequestLimit ?? 0) || 0)),
    pricing: cleanPricing(source.pricing, defaults.pricing),
    enabled: source.enabled === undefined ? true : !!source.enabled,
  };
}

function cleanApiProvider(body, existing) {
  const base = existing || {};
  const incoming = body || {};
  const id = slugProviderId(incoming.id || base.id) ||
    slugProviderId(incoming.name) || `provider-${Date.now()}`;
  const defaults = {
    contextSize: Math.max(0,
      Number(incoming.contextSize ?? base.contextSize ?? 0) || 0),
    maxOutput: Math.max(0,
      Number(incoming.maxOutput ?? base.maxOutput ?? 0) || 0),
    dailyRequestLimit: Math.max(0, Math.floor(
      Number(incoming.dailyRequestLimit ?? base.dailyRequestLimit ?? 0) || 0)),
    pricing: cleanPricing(incoming.pricing, base.pricing),
  };
  const tiers = Array.isArray(incoming.tierAccess)
    ? incoming.tierAccess
    : (Array.isArray(base.tierAccess) ? base.tierAccess : null);
  const tierAccess = tiers
    ? [...new Set(tiers.map((t) => String(t).trim().toLowerCase()).filter(Boolean))]
    : ['free', 'pro', 'vip'];
  // Jenis API upstream. `auto` mendeteksi dari base URL + model ID
  // (Workers AI path, Cloudflare REST /ai/run, OpenAI, Anthropic).
  const formats = ['auto', 'openai', 'anthropic', 'cloudflare',
    'cloudflare-universal'];
  const format = formats.includes(incoming.format)
    ? incoming.format
    : (formats.includes(base.format) ? base.format : 'auto');

  // Daftar model provider. Format lama (satu `model` di level provider)
  // tetap didukung supaya data KV yang sudah ada tidak hilang.
  let rawModels = Array.isArray(incoming.models)
    ? incoming.models
    : (Array.isArray(base.models) ? base.models : null);
  if (!rawModels) {
    const legacy = String(incoming.model ?? base.model ?? '').trim();
    rawModels = legacy
      ? [{
          modelId: legacy,
          name: String(incoming.name ?? base.name ?? legacy),
          contextSize: defaults.contextSize,
          maxOutput: defaults.maxOutput,
          dailyRequestLimit: defaults.dailyRequestLimit,
          pricing: defaults.pricing,
        }]
      : [];
  }
  const models = [];
  const usedKeys = new Set();
  rawModels.forEach((rawModel, index) => {
    const model = cleanProviderModel(rawModel, index, defaults);
    if (!model.modelId) return;
    let key = model.key;
    let suffix = 2;
    while (usedKeys.has(key)) {
      key = `${model.key}-${suffix++}`;
    }
    usedKeys.add(key);
    model.key = key;
    models.push(model);
  });

  return {
    id,
    name: String(incoming.name ?? base.name ?? id).trim() || id,
    baseUrl: String(incoming.baseUrl ?? base.baseUrl ?? '').trim(),
    apiKey: typeof incoming.apiKey === 'string' && incoming.apiKey.trim()
      ? incoming.apiKey.trim()
      : (base.apiKey || ''),
    // Cloudflare AI Gateway id untuk header `cf-aig-gateway-id`
    // (kosong = otomatis `default` untuk model Workers AI `@cf/`).
    gatewayId: String(incoming.gatewayId ?? base.gatewayId ?? '')
      .trim().slice(0, 64),
    format,
    tierAccess: tierAccess.length ? tierAccess : ['free', 'pro', 'vip'],
    models,
    // Cermin legacy untuk klien/admin lama.
    model: models.length ? models[0].modelId : '',
    contextSize: models.length ? models[0].contextSize : defaults.contextSize,
    maxOutput: models.length ? models[0].maxOutput : defaults.maxOutput,
    dailyRequestLimit: defaults.dailyRequestLimit,
    pricing: defaults.pricing,
    enabled: incoming.enabled === undefined
      ? (base.enabled !== false)
      : !!incoming.enabled,
    createdAt: base.createdAt || Date.now(),
    updatedAt: Date.now(),
  };
}

async function apiProviderList(env) {
  const list = await getJson(env.PB_KV, API_PROVIDERS_KEY, []);
  return Array.isArray(list) ? list : [];
}

/// Model efektif milik provider (termasuk data KV format lama).
function apiProviderModels(provider) {
  const list = Array.isArray(provider.models)
    ? provider.models.filter((m) => m && m.modelId)
    : [];
  if (list.length) return list;
  const legacy = String(provider.model || '').trim();
  if (!legacy) return [];
  return [{
    key: 'default',
    modelId: legacy,
    name: String(provider.name || legacy),
    contextSize: Number(provider.contextSize) || 0,
    maxOutput: Number(provider.maxOutput) || 0,
    dailyRequestLimit: Number(provider.dailyRequestLimit) || 0,
    pricing: provider.pricing || {},
    enabled: true,
  }];
}

function apiProviderModelName(provider, model) {
  return String((model && model.modelId) || provider.model || provider.id || '')
    .trim();
}

function isCloudflareApiHost(value) {
  return /(^|\/\/)api\.cloudflare\.com\//i.test(String(value || ''));
}

/// Cara memanggil upstream. Cloudflare punya beberapa endpoint:
/// - `/ai/run/<model>`  → Workers AI path (model di URL, body `{messages}`)
/// - `/ai/run`          → REST universal (body `{model, input}`), bisa untuk
///                        Workers AI maupun model pihak ketiga (openai/…,
///                        anthropic/…, google/…)
/// - `/ai/v1`           → OpenAI-compatible (`/ai/v1/chat/completions`)
/// - `/ai/v1/messages`  → Anthropic Messages
/// Provider lain: OpenAI-compatible `/v1/chat/completions` atau Anthropic
/// `/v1/messages`.
function apiProviderMode(provider, model) {
  const explicit = String(provider.format || 'auto');
  if (['openai', 'anthropic', 'cloudflare', 'cloudflare-universal']
    .includes(explicit)) {
    return explicit;
  }
  const raw = String(provider.baseUrl || '').trim().replace(/\/+$/, '');
  const modelId = apiProviderModelName(provider, model);
  const anthropicHost = /(^|\/\/)api\.anthropic\.com\//i.test(raw);
  const anthropicModel = /^anthropic\//i.test(modelId) ||
    /^claude/i.test(modelId);
  if (/\/ai\/run\/.+/i.test(raw)) return 'cloudflare'; // model sudah di URL
  if (/\/ai\/run$/i.test(raw)) {
    // Model Workers AI memakai endpoint path; model pihak ketiga memakai
    // envelope `/ai/run` (`{model, input}`).
    return modelId.startsWith('@cf/') ? 'cloudflare' : 'cloudflare-universal';
  }
  if (/\/accounts\/[^/]+$/i.test(raw)) return 'cloudflare-universal';
  if (/\/ai\/v1\/messages$/i.test(raw) || /\/v1\/messages$/i.test(raw)) {
    return 'anthropic';
  }
  if (/\/ai\/v1(\/chat\/completions)?$/i.test(raw)) {
    // Cloudflare `/ai/v1` bisa OpenAI-compatible atau Anthropic Messages,
    // tergantung nama model (`anthropic/...`).
    return anthropicModel ? 'anthropic' : 'openai';
  }
  if (/\/chat\/completions$/i.test(raw)) return 'openai';
  if (/\/compat(\/chat\/completions)?$/i.test(raw)) return 'openai';
  if (anthropicHost) return 'anthropic';
  return 'openai';
}

/// URL final yang dipanggil gateway + mode body-nya.
/// Admin cukup menempel salah satu bentuk base URL Cloudflare; sisa path
/// dilengkapi otomatis supaya tidak perlu paham perbedaan endpoint.
function apiProviderTarget(provider, model) {
  const raw = String(provider.baseUrl || '').trim();
  if (!raw) return { url: '', mode: 'openai' };
  const base = raw.replace(/\/+$/, '');
  const modelId = apiProviderModelName(provider, model).replace(/^\/+/, '');
  const mode = apiProviderMode(provider, model);

  if (mode === 'cloudflare') {
    if (/\/ai\/run\/.+/i.test(base)) return { url: base, mode };
    if (/\/ai\/run$/i.test(base)) {
      return { url: `${base}/${modelId}`, mode };
    }
    if (/\/accounts\/[^/]+$/i.test(base)) {
      return { url: `${base}/ai/run/${modelId}`, mode };
    }
    return { url: base, mode };
  }

  if (mode === 'cloudflare-universal') {
    if (/\/ai\/run$/i.test(base)) return { url: base, mode };
    if (/\/ai\/v1$/i.test(base)) {
      return { url: `${base.replace(/\/ai\/v1$/i, '')}/ai/run`, mode };
    }
    if (/\/accounts\/[^/]+$/i.test(base)) {
      return { url: `${base}/ai/run`, mode };
    }
    return { url: base, mode };
  }

  if (mode === 'anthropic') {
    if (/\/messages$/i.test(base)) return { url: base, mode };
    if (/\/ai\/v1$/i.test(base) || /\/v\d+$/i.test(base)) {
      return { url: `${base}/messages`, mode };
    }
    return { url: `${base}/v1/messages`, mode };
  }

  // OpenAI-compatible.
  if (/\/chat\/completions$/i.test(base)) return { url: base, mode };
  if (/\/compat$/i.test(base)) return { url: `${base}/chat/completions`, mode };
  if (/\/ai\/run$/i.test(base)) {
    return {
      url: `${base.replace(/\/ai\/run$/i, '')}/ai/v1/chat/completions`,
      mode,
    };
  }
  if (/\/ai\/v1$/i.test(base) || /\/v\d+$/i.test(base)) {
    return { url: `${base}/chat/completions`, mode };
  }
  return { url: `${base}/v1/chat/completions`, mode };
}

/// Header auth per jenis API. Cloudflare & OpenAI-compatible memakai
/// `Authorization: Bearer`. Anthropic native memakai `x-api-key` +
/// `anthropic-version`, sedangkan endpoint Anthropic milik Cloudflare
/// (`/ai/v1/messages`) tetap memakai Bearer token Cloudflare.
function apiProviderHeaders(provider, mode, model) {
  const headers = new Headers();
  headers.set('Content-Type', 'application/json');
  const key = String(provider.apiKey || '').trim();
  const nativeAnthropic =
    mode === 'anthropic' && /anthropic\.com/i.test(String(provider.baseUrl));
  if (nativeAnthropic) {
    if (key) headers.set('x-api-key', key);
    headers.set('anthropic-version', '2023-06-01');
  } else if (key) {
    headers.set('Authorization', `Bearer ${key}`);
  }
  const gatewayId = String(provider.gatewayId || '').trim();
  const modelId = apiProviderModelName(provider, model);
  if (gatewayId) {
    headers.set('cf-aig-gateway-id', gatewayId);
  } else if (isCloudflareApiHost(provider.baseUrl) &&
      modelId.startsWith('@cf/')) {
    // Workers AI wajib menyebut gateway; `default` dibuat otomatis.
    headers.set('cf-aig-gateway-id', 'default');
  }
  return headers;
}

/// Ubah `content` gaya OpenAI (string atau array part) ke bentuk Anthropic.
function openAiContentToAnthropic(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const blocks = [];
  for (const part of content) {
    if (!part || typeof part !== 'object') continue;
    if (part.type === 'text' && typeof part.text === 'string') {
      blocks.push({ type: 'text', text: part.text });
    } else if (part.type === 'image_url' && part.image_url &&
        typeof part.image_url.url === 'string') {
      const url = part.image_url.url;
      const dataUrl = /^data:([^;]+);base64,(.+)$/i.exec(url);
      if (dataUrl) {
        blocks.push({
          type: 'image',
          source: {
            type: 'base64',
            media_type: dataUrl[1],
            data: dataUrl[2],
          },
        });
      } else if (/^https?:/i.test(url)) {
        blocks.push({ type: 'image', source: { type: 'url', url } });
      }
    }
  }
  if (!blocks.length) return '';
  if (blocks.length === 1 && blocks[0].type === 'text') return blocks[0].text;
  return blocks;
}

/// Body Anthropic Messages dari body OpenAI chat completions.
function openAiToAnthropic(body, modelId, maxTokens) {
  const systemParts = [];
  const messages = [];
  for (const message of Array.isArray(body.messages) ? body.messages : []) {
    if (!message || !message.role) continue;
    const content = openAiContentToAnthropic(message.content);
    if (message.role === 'system' || message.role === 'developer') {
      if (typeof content === 'string') {
        if (content.trim()) systemParts.push(content);
      } else if (Array.isArray(content)) {
        const text = content.filter((block) => block.type === 'text')
          .map((block) => block.text).join('\n');
        if (text.trim()) systemParts.push(text);
      }
      continue;
    }
    if (message.role !== 'user' && message.role !== 'assistant') continue;
    if (content === '' || (Array.isArray(content) && !content.length)) continue;
    messages.push({ role: message.role, content });
  }
  if (!messages.length) messages.push({ role: 'user', content: 'Halo' });
  const result = {
    model: modelId,
    // Anthropic mewajibkan max_tokens.
    max_tokens: Math.max(1, Number(maxTokens) || 1024),
    messages,
  };
  if (systemParts.length) result.system = systemParts.join('\n\n');
  if (body.temperature !== undefined) result.temperature = body.temperature;
  if (body.top_p !== undefined) result.top_p = body.top_p;
  if (body.stop !== undefined) {
    result.stop_sequences = Array.isArray(body.stop) ? body.stop : [body.stop];
  }
  if (body.stream === true) result.stream = true;
  return result;
}

/// Body request sesuai mode upstream.
function apiProviderBody(provider, model, body, maxTokens) {
  const mode = apiProviderMode(provider, model);
  const modelId = apiProviderModelName(provider, model);
  if (mode === 'anthropic') {
    return openAiToAnthropic(body, modelId, maxTokens);
  }
  const base = { ...body, max_tokens: maxTokens };
  delete base.model;
  delete base.stream_options;
  if (mode === 'cloudflare') {
    // Workers AI path: model sudah di URL. `model` tetap dikirim supaya
    // kompatibel dengan proxy/relay yang membacanya.
    return { ...base, model: modelId };
  }
  if (mode === 'cloudflare-universal') {
    // REST universal: { model, input: { ...parameter model } }.
    return { model: modelId, input: base };
  }
  const openai = { ...base, model: modelId };
  if (body.max_completion_tokens !== undefined) {
    openai.max_completion_tokens = maxTokens;
  }
  delete openai.input;
  return openai;
}

/// Ambil teks dari respons non-OpenAI (Anthropic / Workers AI / universal).
function providerText(data) {
  if (!data) return '';
  if (typeof data === 'string') return data;
  if (typeof data.response === 'string') return data.response;
  if (typeof data.output_text === 'string') return data.output_text;
  if (typeof data.text === 'string') return data.text;
  if (Array.isArray(data.content)) {
    return data.content
      .filter((block) => block && block.type === 'text' &&
        typeof block.text === 'string')
      .map((block) => block.text)
      .join('');
  }
  return '';
}

/// Buka pembungkus `{success, result}` milik Cloudflare bila isinya respons
/// chat, tanpa membuang bentuk aslinya kalau bukan.
function unwrapProviderResult(data) {
  if (!data || typeof data !== 'object' || data.result === undefined) {
    return data;
  }
  const inner = data.result;
  if (typeof inner === 'string') return { response: inner };
  if (inner && typeof inner === 'object' &&
      (inner.choices || inner.content || inner.response !== undefined ||
        inner.output_text !== undefined || inner.usage)) {
    return inner;
  }
  return data;
}

/// Normalisasi respons provider apa pun menjadi `chat.completion` OpenAI.
function normalizeProviderChatResponse(data, modelId, fallbackPromptTokens) {
  const root = unwrapProviderResult(data);
  const rawUsage = (root && root.usage) || (data && data.usage) || {};
  let promptTokens = Number(
    rawUsage.prompt_tokens ?? rawUsage.input_tokens) || 0;
  let completionTokens = Number(
    rawUsage.completion_tokens ?? rawUsage.output_tokens) || 0;
  if (!promptTokens) promptTokens = Number(fallbackPromptTokens) || 0;
  // Token prompt yang dilayani dari cache provider (kalau dilaporkan).
  const details = rawUsage.prompt_tokens_details ||
    rawUsage.input_tokens_details || {};
  const cachedTokens = Math.max(0, Number(
    (details && details.cached_tokens) ?? rawUsage.cache_read_input_tokens) || 0);
  const usageOf = () => ({
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
    total_tokens: promptTokens + completionTokens,
    ...(cachedTokens > 0 ? { cached_tokens: cachedTokens } : {}),
  });
  const finish = (text) => {
    if (!completionTokens) {
      completionTokens = Math.max(1, Math.ceil(String(text).length / 4));
    }
    return {
      id: `chatcmpl-${Date.now()}`,
      object: 'chat.completion',
      created: Math.floor(Date.now() / 1000),
      model: modelId,
      choices: [{
        index: 0,
        message: { role: 'assistant', content: text },
        finish_reason: 'stop',
      }],
      usage: usageOf(),
    };
  };
  if (root && Array.isArray(root.choices) && root.choices.length) {
    const message = root.choices[0] && root.choices[0].message;
    if (!completionTokens && message && typeof message.content === 'string') {
      completionTokens = Math.max(1, Math.ceil(message.content.length / 4));
    }
    return {
      ...root,
      id: root.id || `chatcmpl-${Date.now()}`,
      object: 'chat.completion',
      created: root.created || Math.floor(Date.now() / 1000),
      model: modelId,
      usage: usageOf(),
    };
  }
  const text = providerText(root);
  if (text) return finish(text);
  return data;
}

/// Satu event SSE provider → event OpenAI (0..n chunk).
function providerSseChunks(parsed, modelId) {
  if (!parsed || typeof parsed !== 'object') return [];
  // Cloudflare REST/Workers AI bisa membungkus event di `result`.
  const event = unwrapProviderResult(parsed);
  const type = String(event.type || '');
  // Anthropic: teks ada di `content_block_delta.delta.text`.
  if (type === 'content_block_delta') {
    const delta = event.delta || {};
    if (typeof delta.text === 'string' && delta.text) {
      return [providerOpenAiChunk(delta.text, modelId)];
    }
    return [];
  }
  if (type === 'content_block_start') {
    const block = event.content_block || {};
    if (block.type === 'text' && typeof block.text === 'string' && block.text) {
      return [providerOpenAiChunk(block.text, modelId)];
    }
    return [];
  }
  if (type === 'message_start' || type === 'message_delta' ||
      type === 'message_stop' || type === 'ping') {
    return [];
  }
  // OpenAI-compatible (termasuk Cloudflare `/ai/v1/chat/completions`).
  if (Array.isArray(event.choices)) {
    return event.choices.length ? [event] : [];
  }
  // Workers AI / REST universal: `{response: "..."}`.
  const text = providerText(event);
  if (text) return [providerOpenAiChunk(text, modelId)];
  return [];
}

/// Usage dari event SSE (OpenAI, Anthropic, atau universal).
function providerSseUsage(parsed, current) {
  const usage = {};
  const collect = (raw) => {
    if (!raw || typeof raw !== 'object') return;
    const prompt = Number(raw.prompt_tokens ?? raw.input_tokens) || 0;
    const completion = Number(raw.completion_tokens ?? raw.output_tokens) || 0;
    // Token prompt yang dilayani dari cache provider:
    // - OpenAI/Cloudflare: usage.prompt_tokens_details.cached_tokens
    // - Anthropic: usage.cache_read_input_tokens
    const details = raw.prompt_tokens_details || raw.input_tokens_details || {};
    const cached = Number(
      (details && details.cached_tokens) ?? raw.cache_read_input_tokens) || 0;
    if (prompt) usage.prompt_tokens = prompt;
    if (completion) usage.completion_tokens = completion;
    if (cached) {
      usage.cached_tokens = Math.max(Number(usage.cached_tokens) || 0, cached);
    }
  };
  const event = unwrapProviderResult(parsed);
  collect(parsed && parsed.usage);
  collect(event && event.usage);
  collect(event && event.message && event.message.usage);
  return {
    prompt_tokens: usage.prompt_tokens || current.prompt_tokens || 0,
    completion_tokens: usage.completion_tokens || current.completion_tokens || 0,
    cached_tokens: usage.cached_tokens || current.cached_tokens || 0,
  };
}

function dailyDateKey() {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
}

/// Batas request harian efektif dari config: angka admin kalau > 0, selain
/// itu default 20 per akun (bukan tanpa batas).
function effectiveDailyRequestLimit(value) {
  const n = Math.floor(Number(value) || 0);
  return n > 0 ? n : DEFAULT_DAILY_REQUEST_LIMIT;
}

async function dailyRequestUsed(env, accountId) {
  const raw = await env.PB_KV.get(`dailyreq:${accountId}:${dailyDateKey()}`);
  return Number(raw) || 0;
}

/// Batas request harian untuk satu akun. Prioritas:
/// 1. Limit eksplisit admin per akun (akun pro/vip yang di-set manual di
///    dashboard), disimpan di baris akun.
/// 2. Akun tier free → default 15 request/hari.
/// 3. Limit global config (admin) untuk akun dengan tier lain.
function accountDailyRequestLimit(config, account) {
  const override = Math.floor(
    Number((account && account.dailyRequestLimit) || 0) || 0);
  if (override > 0) return override;
  const tier = String((account && account.tier) || '').trim().toLowerCase();
  if (tier === 'guest') return GUEST_DAILY_REQUEST_LIMIT;
  if (tier === 'free') return FREE_DAILY_REQUEST_LIMIT;
  return effectiveDailyRequestLimit(config.dailyRequestLimit);
}

/// Jatah request hari ini untuk satu akun (dipakai Model List aplikasi).
async function accountRequestQuota(env, account, config) {
  const limit = accountDailyRequestLimit(config, account);
  const used = await dailyRequestUsed(env, account.id);
  return {
    date: dailyDateKey(),
    limit,
    used,
    remaining: Math.max(0, limit - used),
    resetAt: dailyResetAt(),
    tier: String((account && account.tier) || ''),
  };
}

async function bumpDailyRequest(env, accountId) {
  const key = `dailyreq:${accountId}:${dailyDateKey()}`;
  const next = (Number(await env.PB_KV.get(key)) || 0) + 1;
  try {
    await env.PB_KV.put(key, String(next), { expirationTtl: 2 * 24 * 60 * 60 });
  } catch {
    // Mock KV lama / KV tanpa opsi tetap harus menyimpan angka.
    await env.PB_KV.put(key, String(next));
  }
  return next;
}

function dailyResetAt() {
  const now = new Date();
  return Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
}

function providerOpenAiChunk(content, model) {
  return {
    id: 'chatcmpl-provider',
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, delta: { content }, finish_reason: null }],
  };
}

/// Bentuk model publik dari provider (tanpa API key) untuk config aplikasi.
/// Nama yang tampil hanya nama model — nama provider tidak dikirim supaya
/// user tidak melihat penyedia API-nya.
function apiProviderModelEntry(provider, model, total) {
  const count = total ?? apiProviderModels(provider).length;
  const tiers = Array.isArray(provider.tierAccess)
    ? provider.tierAccess
    : ['free', 'pro', 'vip'];
  return {
    modelId: apiProviderPublicId(provider, model, count),
    backendModelId: model.modelId,
    name: String(model.name || model.modelId),
    serverId: '__api__',
    serverName: 'AI API',
    serverBaseUrl: '',
    runtime: 'api',
    tierAccess: tiers,
    contextSize: Number(model.contextSize) || 0,
    maxOutput: Number(model.maxOutput) || 0,
    pricing: model.pricing || {},
    dailyRequestLimit: Number(model.dailyRequestLimit) || 0,
    provider: 'external',
  };
}

async function handleApiProviders(request, env, pathname) {
  if (!adminAuthorized(request, env)) {
    return jsonResponse(request, 401, { error: 'Invalid admin key.' });
  }

  // POST /api/admin/api-providers/test — tes koneksi ke provider.
  if (pathname === '/api/admin/api-providers/test' &&
      request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const list = await apiProviderList(env);
    const submittedId = slugProviderId(body.id || '');
    const existing = submittedId
      ? list.find((p) => slugProviderId(p.id) === submittedId)
      : null;
    const provider = cleanApiProvider(body, existing);
    const testModel = apiProviderModels(provider)
      .find((m) => m.enabled !== false) || apiProviderModels(provider)[0];
    const target = apiProviderTarget(provider, testModel);
    if (!target.url || !provider.apiKey) {
      return jsonResponse(request, 400, {
        error: 'Base URL dan API key wajib diisi untuk tes koneksi.',
      });
    }
    if (!testModel) {
      return jsonResponse(request, 400, {
        error: 'Tambahkan minimal satu model untuk dites.',
      });
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const res = await fetch(target.url, {
        method: 'POST',
        headers: apiProviderHeaders(provider, target.mode, testModel),
        body: JSON.stringify(apiProviderBody(provider, testModel, {
          messages: [{ role: 'user', content: 'ping' }],
          max_tokens: 8,
          stream: false,
        }, 8)),
        signal: controller.signal,
      });
      const text = await res.text();
      return jsonResponse(request, 200, {
        ok: res.ok,
        status: res.status,
        target: target.url,
        mode: target.mode,
        preview: text.slice(0, 400),
      });
    } catch (error) {
      return jsonResponse(request, 502, {
        ok: false,
        error: `Gagal menghubungi provider: ${error}`,
        target: target.url,
        mode: target.mode,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  // GET /api/admin/api-providers — daftar provider (API key disamarkan).
  if (pathname === '/api/admin/api-providers' && request.method === 'GET') {
    const list = await apiProviderList(env);
    return jsonResponse(request, 200, {
      providers: list.map((p) => ({
        ...p,
        apiKey: '',
        hasApiKey: !!p.apiKey,
      })),
    });
  }

  // POST /api/admin/api-providers — tambah / ubah provider.
  if (pathname === '/api/admin/api-providers' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const list = await apiProviderList(env);
    const submittedId = slugProviderId(body.id || body.name || '');
    const idx = submittedId
      ? list.findIndex((p) => slugProviderId(p.id) === submittedId)
      : -1;
    const entry = cleanApiProvider(body, idx >= 0 ? list[idx] : null);
    if (!entry.baseUrl || !/^https?:\/\//i.test(entry.baseUrl)) {
      return jsonResponse(request, 400, {
        error: 'Base URL wajib diisi dan diawali http:// atau https://.',
      });
    }
    if (!entry.models.length) {
      return jsonResponse(request, 400, {
        error: 'Tambahkan minimal satu model (mis. @cf/moonshotai/kimi-k2.7-code).',
      });
    }
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      // Jangan pernah punya dua provider dengan id yang sama.
      if (list.some((p) => slugProviderId(p.id) === slugProviderId(entry.id))) {
        entry.id = `${entry.id}-${list.length + 1}`;
      }
      list.push(entry);
    }
    await env.PB_KV.put(API_PROVIDERS_KEY, JSON.stringify(list));
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, {
      ok: true,
      provider: { ...entry, apiKey: '', hasApiKey: !!entry.apiKey },
    });
  }

  // DELETE /api/admin/api-providers/:id
  const deleteMatch = pathname.match(/^\/api\/admin\/api-providers\/(.+)$/);
  if (deleteMatch && request.method === 'DELETE') {
    const id = decodeURIComponent(deleteMatch[1]);
    const list = await apiProviderList(env);
    const filtered = list.filter(
      (p) => slugProviderId(p.id) !== slugProviderId(id));
    await env.PB_KV.put(API_PROVIDERS_KEY, JSON.stringify(filtered));
    await invalidateModelCaches(env);
    return jsonResponse(request, 200, { ok: true, deleted: id });
  }

  return jsonResponse(request, 404, {
    error: 'Unknown api-providers endpoint.',
  });
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
    // Batas request harian per akun (default 20). Provider API eksternal
    // bisa punya limit sendiri yang lebih ketat.
    dailyRequestLimit: effectiveDailyRequestLimit(config.dailyRequestLimit),
    // Hanya alamat server yang publik. Secret key TIDAK pernah dibuka di
    // endpoint publik — dikirim ke user yang sudah login lewat /api/auth/me.
    aiServerUrl: config.aiServerUrl || '',
    managerUrl: config.managerUrl || '',
    // Prompt global admin ikut ke aplikasi lewat config publik (bukan rahasia).
    systemPrompt: (config.systemPrompt || '').trim(),
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

/// Lazy expiry membership: kalau paket VIP/Pro akun sudah habis masanya
/// (plan.expiresAt <= sekarang), akun otomatis kembali ke tier gratis
/// dengan limit request admin (plan.prevDailyReqLimit / kalau 0 = aturan
/// tier free). Dipanggil setiap kali akun dibaca dari KV supaya tidak perlu
/// cron job terpisah.
async function applyPlanExpiry(env, account) {
  if (!account) return account;
  const plan = account.plan;
  if (!plan || typeof plan !== 'object') return account;
  const expiresAt = Number(plan.expiresAt) || 0;
  if (expiresAt <= 0) return account;
  if (Date.now() < expiresAt) return account;
  const next = { ...account };
  next.tier = (typeof plan.prevTier === 'string' && plan.prevTier) || 'free';
  next.dailyRequestLimit = Math.max(0, Math.floor(Number(plan.prevDailyReqLimit) || 0));
  delete next.plan;
  await env.PB_KV.put(`account:${account.id}`, JSON.stringify(next));
  return next;
}

async function sessionAccount(env, request) {
  const token = bearerToken(request);
  if (!token) return null;
  const accountId = await env.PB_KV.get(`session:${token}`);
  if (!accountId) return null;
  const account = await getJson(env.PB_KV, `account:${accountId}`, null);
  if (!account) return null;
  return { token, account: await applyPlanExpiry(env, account) };
}

/// Akun dari `Authorization: Bearer <sesi Discord | API key user>`.
/// Dipakai gateway & endpoint kuota request. Hasilnya `{ account }` atau
/// `{ status, error }` siap dikirim sebagai respons.
async function accountFromBearer(env, request) {
  const bearer = bearerToken(request);
  if (!bearer) {
    return {
      status: 401,
      error: 'Missing API key. Use Authorization: Bearer <your-api-key>',
    };
  }
  const keyHash = await hashApiKey(bearer);
  const keyData = await getJson(env.PB_KV, `apikey:${keyHash}`, null);
  if (keyData) {
    if (keyData.deleteAt && Date.now() >= keyData.deleteAt) {
      await env.PB_KV.delete(`apikey:${keyHash}`);
      return { status: 401, error: 'API key has been deleted.' };
    }
    if (keyData.deleteAt) {
      return {
        status: 403,
        error: 'API key is pending deletion.',
        deleteAt: keyData.deleteAt,
      };
    }
    const account = await getJson(
      env.PB_KV, `account:${keyData.accountId}`, null);
    return account
      ? { account: await applyPlanExpiry(env, account) }
      : { status: 401, error: 'Invalid API key.' };
  }
  // Bukan API key → coba session token login. Nilai session di KV adalah
  // string accountId (bukan JSON).
  const sessionAccountId = await env.PB_KV.get(`session:${bearer}`);
  const account = sessionAccountId
    ? await getJson(env.PB_KV, `account:${sessionAccountId}`, null)
    : null;
  return account
    ? { account: await applyPlanExpiry(env, account) }
    : { status: 401, error: 'Invalid API key.' };
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
        // Model yang disembunyikan admin tidak pernah ditawarkan ke user.
        .filter((m) => m.enabled !== false)
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
      // Provider API eksternal (base URL + API key di dashboard admin).
      // Modelnya ikut tampil di aplikasi dan request lewat gateway.
      const providers = await apiProviderList(env);
      for (const provider of providers) {
        if (!provider || !provider.id || provider.enabled === false) continue;
        const providerModels = apiProviderModels(provider);
        for (const model of providerModels) {
          if (model.enabled === false) continue;
          models.push(apiProviderModelEntry(
            provider, model, providerModels.length));
        }
      }
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

  // GET /api/auth/request-quota — sisa request harian akun (Model List).
  // Bisa memakai sesi Discord atau AI API key milik user.
  if (pathname === '/api/auth/request-quota' && request.method === 'GET') {
    const auth = await accountFromBearer(env, request);
    if (!auth.account) {
      return jsonResponse(request, auth.status || 401, {
        error: auth.error || 'Login required to read request quota.',
        ...(auth.deleteAt ? { deleteAt: auth.deleteAt } : {}),
      });
    }
    if (auth.account.status === 'banned') {
      return jsonResponse(request, 403, { error: 'This account is banned.' });
    }
    return jsonResponse(
      request, 200, await accountRequestQuota(env, auth.account, config));
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

  // GET /api/admin/model-stats — cache/pemakaian per model untuk dashboard.
  if (pathname === '/api/admin/model-stats' && request.method === 'GET') {
    const rows = await modelCacheStats(env);
    const models = await getJson(env.PB_KV, 'server_models', []);
    const byId = new Map(models.map((m) => [String(m.modelId), m]));
    return jsonResponse(request, 200, {
      models: rows.map((row) => {
        const model = byId.get(row.modelId) || {};
        return {
          ...row,
          name: model.name || row.name,
          serverId: String(model.serverId || ''),
          contextSize: Number(model.contextSize) || 0,
          maxOutput: Number(model.maxOutput) || 0,
          enabled: model.enabled !== false,
          active: model.active !== false,
        };
      }),
    });
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
        // Batas request per akun per hari untuk semua model gateway.
        dailyRequestLimit: config.dailyRequestLimit ?? 0,
        botSecretKey: config.botSecretKey || '',
        hasBotSecret: !!config.botSecretKey,
        aiServerUrl: config.aiServerUrl || '',
        localCloudKey: config.localCloudKey || '',
        managerUrl: config.managerUrl || '',
        managerSecretKey: config.managerSecretKey || '',
        systemPrompt: config.systemPrompt || '',
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
      if (typeof body.dailyRequestLimit === 'number' &&
          body.dailyRequestLimit >= 0) {
        next.dailyRequestLimit = Math.floor(body.dailyRequestLimit);
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
      // Prompt global: string kosong = kembali ke prompt bawaan aplikasi.
      // Dibatasi supaya KV tidak bisa diisi teks raksasa.
      if (typeof body.systemPrompt === 'string') {
        next.systemPrompt = body.systemPrompt.trim().slice(0, 12000);
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
      if (account) accounts.push(await applyPlanExpiry(env, account));
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
        ...existing,
        id,
        name: String(body.name ?? existing.name ?? ''),
        role: body.role === 'admin' ? 'admin'
          : (existing.role === 'admin' ? 'admin' : 'user'),
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
        dailyRequestLimit: Number.isFinite(+body.dailyRequestLimit)
          ? Math.max(0, Math.floor(+body.dailyRequestLimit))
          : (existing.dailyRequestLimit ?? 0),
        lastReset: Number.isFinite(+body.lastReset)
          ? Math.floor(+body.lastReset)
          : (existing.lastReset ?? now),
        status: body.status === 'banned' ? 'banned' : 'active',
        discordId: String(body.discordId ?? existing.discordId ?? '').trim(),
        createdAt: existing.createdAt ?? now,
      };
      // Konsistensi: tier di-set manual beda dengan plan aktif → plan dihapus.
      if (!body.planAction && !body.planTier && account.plan) {
        if (String(account.plan.tier || '') !== String(account.tier || '')) {
          delete account.plan;
        }
      }
      // Plan membersihkan/mengubah tier secara manual di dashboard.
      //   body.planAction = 'clear'          → hapus plan, tier kembali free
      //   body.planTier = 'vip' | 'pro'      → beri/perpanjang plan 30 hari
      //   body.planDays = N (opsional)       → perpanjang N hari (default 30)
      if (body.planAction === 'clear') {
        delete account.plan;
        account.tier = 'free';
        account.dailyRequestLimit = 0;
      } else if (typeof body.planTier === 'string' &&
                 PLAN_TIERS.includes(String(body.planTier).toLowerCase()) &&
                 String(body.planTier).toLowerCase() !== 'none') {
        const tier = String(body.planTier).toLowerCase();
        const days = Number.isFinite(+body.planDays)
          ? Math.max(1, Math.floor(+body.planDays))
          : PLAN_MEMBERSHIP_DURATION_DAYS;
        const prevTier = String(account.tier || 'free')
          .replace(/^(vip|pro)$/, 'free');
        account.plan = {
          id: `admin-${tier}-${now.toString(36)}`,
          name: tier.toUpperCase(),
          tier,
          expiresAt: now + days * MS_PER_DAY,
          durationDays: days,
          createdAt: now,
          prevTier,
          prevDailyReqLimit: Math.max(0,
            Math.floor(Number(existing.dailyRequestLimit) || 0)),
        };
        account.tier = tier;
        // dailyReqLimit admin-set atau membership-default kalau kosong.
        if (!(Number(account.dailyRequestLimit) > 0)) {
          account.dailyRequestLimit = tier === 'pro' ? 45 : 30;
        }
      }
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

  // ─── Plans: paket berbayar (credit pack + membership) ────────────────
  if (pathname === '/api/admin/plans') {
    if (request.method === 'GET') {
      return jsonResponse(request, 200, {
        plans: await getPlans(env),
        wallets: await getWallets(env),
      });
    }
    if (request.method === 'POST') {
      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
      }
      const raw = Array.isArray(body && body.plans) ? body.plans : null;
      if (!raw) {
        return jsonResponse(request, 400, { error: '"plans" harus array.' });
      }
      const cleaned = [];
      const seen = new Set();
      for (let i = 0; i < raw.length && cleaned.length < 50; i++) {
        const plan = cleanPlan(raw[i], `plan-${i}`);
        if (!plan || seen.has(plan.id)) continue;
        seen.add(plan.id);
        cleaned.push(plan);
      }
      if (cleaned.length === 0) {
        return jsonResponse(request, 400, { error: 'Minimal satu plan.' });
      }
      // Sort biar urutan di UI konsisten.
      cleaned.sort((a, b) => a.sort - b.sort);
      await env.PB_KV.put('plans', JSON.stringify(cleaned));
      return jsonResponse(request, 200, { ok: true, plans: cleaned });
    }
  }

  // ─── Plans: wallet ACC pembayaran (ShopeePay/GoPay) ─────────────────
  if (pathname === '/api/admin/wallets') {
    if (request.method === 'GET') {
      return jsonResponse(request, 200, { wallets: await getWallets(env) });
    }
    if (request.method === 'POST') {
      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
      }
      const raw = Array.isArray(body && body.wallets) ? body.wallets : null;
      if (!raw) {
        return jsonResponse(request, 400, { error: '"wallets" harus array.' });
      }
      const cleaned = [];
      for (let i = 0; i < raw.length && cleaned.length < 20; i++) {
        const wallet = cleanWallet(raw[i], `wallet-${i}`);
        if (wallet) cleaned.push(wallet);
      }
      // Wajib ada minimal satu wallet aktif dengan nomor/VA agar user bisa bayar.
      if (cleaned.length === 0) {
        return jsonResponse(request, 400, {
          error: 'Minimal satu wallet dengan nomor/va harus diisi.',
        });
      }
      await env.PB_KV.put('payment_wallets', JSON.stringify(cleaned));
      return jsonResponse(request, 200, { ok: true, wallets: cleaned });
    }
  }

  // ─── Plans: pesanan pembelian ───────────────────────────────────────
  if (pathname === '/api/admin/plan-orders' && request.method === 'GET') {
    const url = new URL(request.url);
    const status = (url.searchParams.get('status') || 'all').toLowerCase();
    const all = await getPlanOrders(env);
    const filtered = status === 'all'
      ? all
      : all.filter((o) => o.status === status);
    // Bukti dikirim sebagai data URL — tampilkan tapi potong agar respons ringan.
    const orders = filtered.map((o) => ({
      ...o,
      proof: o.proof
        ? (o.proof.length > 120000 ? o.proof.slice(0, 120000) + '#truncated' : o.proof)
        : '',
    }));
    return jsonResponse(request, 200, { orders });
  }

  if (pathname.startsWith('/api/admin/plan-orders/')) {
    const parts = pathname.split('/').filter(Boolean);
    // ['api', 'admin', 'plan-orders', '<id>', '<action>']
    const id = decodeURIComponent(parts[3] || '');
    const action = parts[4] || '';
    if (!id) {
      return jsonResponse(request, 400, { error: 'Order id wajib.' });
    }
    const orders = await getPlanOrders(env);
    const idx = orders.findIndex((o) => o.id === id);
    if (idx < 0) {
      return jsonResponse(request, 404, { error: 'Pesanan tidak ditemukan.' });
    }
    if (action === 'approve' && request.method === 'POST') {
      if (orders[idx].status !== 'pending') {
        return jsonResponse(request, 409, { error: 'Pesanan sudah diproses.' });
      }
      const grants = orders[idx].grants || {};
      const key = `account:${orders[idx].accountId}`;
      const existing = await getJson(env.PB_KV, key, null);
      if (!existing) {
        return jsonResponse(request, 404, { error: 'Akun tidak ditemukan.' });
      }
      const credits = Math.max(0, Number(grants.credits) || 0);
      const tokenBonus = Math.max(0, Math.floor(Number(grants.tokenBonus) || 0));
      const tier = PLAN_TIERS.includes(String(grants.tier)) ? grants.tier : 'none';
      const dailyReqLimit = Math.max(0, Math.floor(Number(grants.dailyReqLimit) || 0));
      const durationDays = Math.max(0, Math.floor(Number(grants.durationDays) ||
        (PLAN_MEMBERSHIP_DURATION_DAYS)));
      existing.creditBalance =
        Math.round((Number(existing.creditBalance || 0) + credits) * 1e8) / 1e8;
      existing.tokenBalance =
        Math.floor(Number(existing.tokenBalance || 0) + tokenBonus);
      if (tier !== 'none') {
        const prevTier = String(existing.tier || 'free').toLowerCase() || 'free';
        const prevLimit = Math.max(0, Math.floor(Number(existing.dailyRequestLimit) || 0));
        existing.tier = tier;
        if (dailyReqLimit > 0) existing.dailyRequestLimit = dailyReqLimit;
        // Membership 30 hari: simpan plan + tanggal kedaluwarsa.
        // Saat habis, applyPlanExpiry() mengembalikan tier & limit ke semula.
        existing.plan = {
          id: String(grants.planId || ''),
          name: String(grants.planName || grants.tier),
          tier,
          expiresAt: Date.now() + durationDays * MS_PER_DAY,
          durationDays,
          createdAt: Date.now(),
          prevTier,
          prevDailyReqLimit: prevLimit,
        };
      }
      existing.planLastPurchaseAt = Date.now();
      await env.PB_KV.put(key, JSON.stringify(existing));
      orders[idx].status = 'paid';
      orders[idx].approvedAt = Date.now();
      orders[idx].updatedAt = Date.now();
      await savePlanOrders(env, orders);
      return jsonResponse(request, 200, {
        ok: true,
        order: { id: orders[idx].id, status: orders[idx].status },
        account: existing,
      });
    }
    if (action === 'reject' && request.method === 'POST') {
      if (orders[idx].status !== 'pending') {
        return jsonResponse(request, 409, { error: 'Pesanan sudah diproses.' });
      }
      let reason = 'Ditolak admin.';
      try {
        const body = await request.json().catch(() => ({}));
        if (body && typeof body.reason === 'string') {
          reason = body.reason.slice(0, 200);
        }
      } catch {
        // biarkan default
      }
      orders[idx].status = 'rejected';
      orders[idx].reason = reason;
      orders[idx].updatedAt = Date.now();
      await savePlanOrders(env, orders);
      return jsonResponse(request, 200, {
        ok: true,
        order: { id: orders[idx].id, status: orders[idx].status },
      });
    }
    return jsonResponse(request, 404, { error: 'Aksi tidak dikenal.' });
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
      // Status tampil/sembunyi dipertahankan saat deteksi ulang.
      enabled: existing ? (existing.enabled !== false) : true,
      // Nilai dari `/props` server menang; kalau server tidak melaporkannya,
      // nilai terakhir dipertahankan supaya UI tidak kosong.
      contextSize: Number(item.contextSize) ||
        (existing ? (Number(existing.contextSize) || 0) : 0),
      maxOutput: Number(item.maxOutput) ||
        (existing ? (Number(existing.maxOutput) || 0) : 0),
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
  // Batas context/max output dibaca dari server (llama-server `/props`),
  // bukan ditebak admin. Gagal membaca props bukan error: model tetap
  // terdeteksi, nilainya cuma 0 (belum diketahui).
  const props = await fetchAiProps(clean, secret);
  return { ids: [...new Set(ids)], url: clean, props };
}

/// Baca `/props` server AI (llama-server) untuk mengetahui context dan batas
/// output yang benar-benar dipakai server. Nilai ini dipakai dashboard dan
/// dikirim ke aplikasi supaya UI menampilkan angka yang sama dengan server.
async function fetchAiProps(base, secret) {
  const clean = String(base || '').trim().replace(/\/+$/, '');
  if (!clean) return { contextSize: 0, maxOutput: 0, slots: 0, model: '' };
  const root = /\/v\d+$/i.test(clean)
    ? clean.replace(/\/v\d+$/i, '')
    : clean;
  const headers = { Accept: 'application/json' };
  if (secret) {
    headers['X-Secret-Key'] = secret;
    headers.Authorization = `Bearer ${secret}`;
  }
  let payload = null;
  // llama-server: `/props`. Sebagian build lama hanya punya `/v1/props`.
  for (const url of [`${root}/props`, `${clean}/props`]) {
    try {
      const res = await fetch(url, { headers });
      if (!res.ok) continue;
      const data = await res.json();
      if (data && typeof data === 'object') {
        payload = data;
        break;
      }
    } catch (_) {
      // Coba URL berikutnya.
    }
  }
  if (!payload) return { contextSize: 0, maxOutput: 0, slots: 0, model: '' };
  const slots = Math.max(1, Number(payload.total_slots) || 1);
  const generation = payload.default_generation_settings || {};
  // `n_ctx` di default_generation_settings = context PER SLOT. Total context
  // server = n_ctx * total_slots (llama-server membagi context ke tiap slot).
  const ctxPerSlot = Number(payload.n_ctx) || Number(generation.n_ctx) || 0;
  const contextSize = ctxPerSlot > 0 ? Math.floor(ctxPerSlot * slots) : 0;
  // `n_predict` = batas output default; -1 (tanpa batas) → pakai perkiraan
  // aman seperdua context, dibatasi 4096 supaya jawaban tidak menggantung.
  const nPredict = Number(generation.n_predict);
  const maxOutput = nPredict > 0
    ? Math.floor(nPredict)
    : (contextSize > 0
      ? Math.min(4096, Math.max(256, Math.floor(contextSize / 2)))
      : 0);
  const modelPaths = payload.model_path ? [payload.model_path] : [];
  return {
    contextSize,
    maxOutput,
    slots,
    model: backendModelName(modelPaths[0] || ''),
  };
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

/// Lengkapi hasil deteksi dengan context/max output dari `/props` tiap
/// endpoint AI (satu proses llama-server = satu daemon).
async function attachDetectedProps(detected, secret) {
  const urls = [...new Set(
    detected.map((m) => String(m.apiUrl || '').trim()).filter(Boolean))];
  const byUrl = new Map();
  await Promise.all(urls.map(async (url) => {
    byUrl.set(url, await fetchAiProps(url, secret));
  }));
  for (const item of detected) {
    const props = byUrl.get(String(item.apiUrl || '').trim());
    if (!props) continue;
    item.contextSize = props.contextSize;
    item.maxOutput = props.maxOutput;
  }
  return detected;
}

async function detectViaManager(env, server) {
  const raw = normalizePublicUrl(server.managerUrl);
  if (!raw) throw new Error('Base URL AI server belum diisi.');

  // URL yang berakhiran /manager → flow lama (daemon manager.py).
  if (/\/manager\/?$/i.test(raw)) {
    try {
      const daemons = await fetchManagerServers(server);
      const detected = await attachDetectedProps(
        detectedModelsFromManager(daemons), server.managerKey);
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
  const { ids, url, props } = await fetchAiModels(target, server.managerKey);
  server.baseUrl = url;
  const detected = ids.map((id) => ({
    backendId: backendModelName(id),
    daemonId: '',
    apiUrl: url,
    runtime: server.runtime || '',
    contextSize: props.contextSize,
    maxOutput: props.maxOutput,
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
    account = await applyPlanExpiry(env, account);

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
    account = await applyPlanExpiry(env, account);
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
    account = await applyPlanExpiry(env, account);
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

/// Deteksi model AI lokal (self-hosted): host-nya private/loopback atau ada
/// flag eksplisit. Model lokal tidak pernah boleh dibatasi dulu oleh tier.
function isSelfHostedAi(serverConfig, modelConfig) {
  const flags = [
    serverConfig && serverConfig.baseUrl,
    serverConfig && serverConfig.apiUrl,
    modelConfig && modelConfig.apiUrl,
    modelConfig && modelConfig.serverUrl,
    modelConfig && modelConfig.serverBaseUrl,
  ];
  const localHints = [
    'localhost', '127.0.0.1', '192.168.', '10.', '172.16.', '172.17.',
    '172.18.', '172.19.', '172.20.', '172.21.', '172.22.', '172.23.',
    '172.24.', '172.25.', '172.26.', '172.27.', '172.28.', '172.29.',
    '172.30.', '172.31.',
  ];
  for (const value of flags) {
    const raw = String((value && value.href) || value || '');
    const lower = raw.toLowerCase();
    if (localHints.some((hint) => lower.includes(hint))) return true;
  }
  return !!(modelConfig && modelConfig.local);
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

// ── Batas max_tokens dari server ─────────────────────────────────────────
// Context & max output diisi otomatis dari `/props` server manager. Gateway
// memakai angka itu untuk membatasi permintaan user, jadi server tidak
// pernah menerima output lebih panjang dari yang bisa diprosesnya.

const GATEWAY_HARD_MAX_TOKENS = 8192;

/// Perkiraan token prompt dari isi pesan (≈4 karakter/token, bahasa campur).
function estimatePromptTokens(messages) {
  if (!Array.isArray(messages)) return 0;
  let chars = 0;
  for (const message of messages) {
    if (!message) continue;
    const content = message.content;
    if (typeof content === 'string') {
      chars += content.length;
    } else if (Array.isArray(content)) {
      for (const part of content) {
        if (part && typeof part.text === 'string') chars += part.text.length;
      }
    }
    chars += 8; // role + pemisah pesan
  }
  return chars > 0 ? Math.ceil(chars / 4) + 8 : 0;
}

/// Hitung `max_tokens` efektif: `min(permintaan, maxOutput, sisa context)`.
/// Bila prompt sudah melebihi context, kembalikan `error` yang jelas supaya
/// user tidak melihat kegagalan backend yang membingungkan.
function resolveMaxTokens(body, modelConfig) {
  const contextSize = Number(modelConfig.contextSize) || 0;
  const maxOutput = Number(modelConfig.maxOutput) || 0;
  const requested = Number(body.max_tokens ?? body.max_completion_tokens) || 0;
  // Tanpa permintaan eksplisit, pakai batas output server (atau 4096).
  let limit = requested > 0 ? requested : (maxOutput || 4096);
  if (maxOutput > 0) limit = Math.min(limit, maxOutput);
  limit = Math.min(limit, GATEWAY_HARD_MAX_TOKENS);
  const promptEstimate = estimatePromptTokens(body.messages);
  if (contextSize > 0) {
    const room = contextSize - promptEstimate - 32;
    if (room <= 0) {
      return {
        error: `Pesan terlalu panjang: perkiraan ${promptEstimate} token, ` +
          `context model ini ${contextSize} token. Perpendek pesan atau ` +
          'mulai chat baru.',
        promptEstimate,
        contextSize,
      };
    }
    limit = Math.min(limit, room);
  }
  return {
    maxTokens: Math.max(1, Math.floor(limit)),
    promptEstimate,
    contextSize,
    maxOutput,
    requested,
  };
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
  const auth = await accountFromBearer(env, request);
  if (!auth.account) {
    return jsonResponse(request, auth.status || 401, {
      error: auth.error || 'Invalid API key.',
      ...(auth.deleteAt ? { deleteAt: auth.deleteAt } : {}),
    });
  }
  let account = auth.account;
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
        const list = serverModels
          .filter(m => {
            // Model yang disembunyikan admin tidak boleh dipakai user.
            if (m.enabled === false) return false;
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
        // Provider API eksternal: daftarkan modelnya (tanpa API key).
        const providers = await apiProviderList(env);
        for (const provider of providers) {
          if (!provider || !provider.id || provider.enabled === false) continue;
          const providerModels = apiProviderModels(provider);
          for (const model of providerModels) {
            if (model.enabled === false) continue;
            const entry = apiProviderModelEntry(
              provider, model, providerModels.length);
            const tiers = entry.tierAccess || ['free', 'pro', 'vip'];
            if (!tiers.includes(userTier)) continue;
            list.push(entry);
          }
        }
        return list;
      });
    const filtered = cached.value || [];
    // Id publik tidak pernah berupa nama/path file. Entri lama yang belum
    // di-sync ulang tetap ditampilkan dengan id `<label>:<model>:<tier>`.
    // Model provider eksternal sudah memakai id `api:<id>` apa adanya.
    const withPublicId = filtered.map((m) => ({
      ...m,
      modelId: m.provider === 'external'
        ? m.modelId
        : gatewayPublicIdFor(m, servers),
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

  // GET /api/gateway/plans — daftar paket aktif (tanpa secret).
  if (pathname === '/api/gateway/plans' && request.method === 'GET') {
    const plans = (await getPlans(env)).filter((p) => p.active !== false);
    return jsonResponse(request, 200, {
      object: 'list',
      data: plans.map((p) => ({
        id: p.id,
        name: p.name,
        kind: p.kind,
        priceIdr: p.priceIdr,
        credits: p.credits,
        tokenBonus: p.tokenBonus,
        tier: p.tier,
        dailyReqLimit: p.dailyReqLimit,
        durationDays: p.durationDays || 0,
        description: p.description,
      })),
    });
  }

  // POST /api/gateway/plans/order — buat pesanan paket (menunggu bayar).
  if (pathname === '/api/gateway/plans/order' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const planId = String((body && body.planId) || '').trim();
    const method = String((body && body.method) || '').trim().toLowerCase();
    if (!WALLET_TYPES.includes(method)) {
      return jsonResponse(request, 400, {
        error: 'Metode pembayaran tidak didukung. Gunakan: shopeepay / gopay.',
      });
    }
    const plans = await getPlans(env);
    const plan = plans.find((p) => p.id === planId && p.active !== false);
    if (!plan) {
      return jsonResponse(request, 404, { error: 'Paket tidak ditemukan / nonaktif.' });
    }
    const wallets = (await getWallets(env)).filter((w) => w.active && w.account);
    if (wallets.length === 0) {
      return jsonResponse(request, 503, {
        error: 'Pembayaran belum dikonfigurasi admin. Kami beri tahu setelah aktif.',
      });
    }
    const orders = await getPlanOrders(env);
    const id = `po_${Date.now().toString(36)}_${crypto.randomUUID().slice(0, 8)}`;
    const order = {
      id,
      accountId: account.id,
      accountName: account.name || '',
      accountDiscordId: account.discordId || '',
      planId: plan.id,
      planName: plan.name,
      kind: plan.kind,
      priceIdr: plan.priceIdr,
      method,
      status: 'pending',
      proof: '',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      grants: {
        credits: plan.credits,
        tokenBonus: plan.tokenBonus,
        tier: plan.tier,
        dailyReqLimit: plan.dailyReqLimit,
        planId: plan.id,
        planName: plan.name,
        kind: plan.kind,
        durationDays: plan.durationDays || 0,
      },
    };
    orders.unshift(order);
    await savePlanOrders(env, orders);
    return jsonResponse(request, 200, {
      order: {
        id: order.id,
        planId: order.planId,
        planName: order.planName,
        priceIdr: order.priceIdr,
        method,
        status: 'pending',
        createdAt: order.createdAt,
      },
      wallets: wallets.map((w) => ({
        type: w.type,
        label: w.label,
        account: w.account,
        note: w.note || '',
      })),
      message: 'Transfer sesuai nominal, lalu unggah bukti pembayaran di halaman Plans.',
    });
  }

  // POST /api/gateway/plans/order/proof — unggah bukti pembayaran.
  if (pathname === '/api/gateway/plans/order/proof' && request.method === 'POST') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(request, 400, { error: 'Invalid JSON body.' });
    }
    const orderId = String((body && body.orderId) || '').trim();
    const dataUrl = String((body && body.dataUrl) || '');
    if (!orderId) {
      return jsonResponse(request, 400, { error: 'orderId wajib.' });
    }
    if (!/^data:image\/(jpeg|jpg|png|webp);base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) {
      return jsonResponse(request, 400, {
        error: 'Bukti harus berupa gambar JPEG/PNG/WebP (data URL).',
      });
    }
    if (dataUrl.length > 450000) {
      return jsonResponse(request, 413, {
        error: 'Bukti terlalu besar. Kompres dulu (maks ~320 KB).',
      });
    }
    const orders = await getPlanOrders(env);
    const idx = orders.findIndex(
      (o) => o.id === orderId && o.accountId === account.id);
    if (idx < 0) {
      return jsonResponse(request, 404, { error: 'Pesanan tidak ditemukan.' });
    }
    if (orders[idx].status !== 'pending') {
      return jsonResponse(request, 409, {
        error: 'Pesanan sudah diproses admin.',
      });
    }
    orders[idx].proof = dataUrl;
    orders[idx].updatedAt = Date.now();
    await savePlanOrders(env, orders);
    return jsonResponse(request, 200, {
      ok: true,
      order: {
        id: orders[idx].id,
        status: orders[idx].status,
        updatedAt: orders[idx].updatedAt,
      },
    });
  }

  // GET /api/gateway/plans/orders — pesanan milik user ini.
  if (pathname === '/api/gateway/plans/orders' && request.method === 'GET') {
    const orders = await getPlanOrders(env);
    return jsonResponse(request, 200, {
      orders: orders
        .filter((o) => o.accountId === account.id)
        .slice(0, 20)
        .map((o) => ({
          id: o.id,
          planId: o.planId,
          planName: o.planName,
          priceIdr: o.priceIdr,
          method: o.method,
          status: o.status,
          hasProof: !!(o.proof && o.proof.length > 0),
          createdAt: o.createdAt,
          updatedAt: o.updatedAt,
        })),
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
    const providers = await apiProviderList(env);
    const wantedBackend = backendModelName(wantedModel);
    let providerConfig = null;
    let providerModel = null;
    let modelConfig =
      serverModels.find((m) => String(m.modelId) === wantedModel) ||
      serverModels.find((m) =>
        backendModelName(m.backendModelId || m.modelId) === wantedBackend) ||
      serverModels.find((m) =>
        gatewayPublicIdFor(m, servers) === wantedModel);
    // Bukan model server lokal → coba provider API eksternal (`api:<id>`).
    if (!modelConfig) {
      for (const provider of providers) {
        if (!provider || !provider.id) continue;
        const list = apiProviderModels(provider);
        for (const model of list) {
          const publicId = apiProviderPublicId(provider, model, list.length);
          if (publicId === wantedModel ||
              String(model.key) === wantedModel ||
              String(model.modelId) === wantedModel ||
              backendModelName(model.modelId) === wantedBackend) {
            providerConfig = provider;
            providerModel = model;
            break;
          }
        }
        if (providerConfig) break;
      }
      if (providerConfig) {
        modelConfig = {
          modelId: apiProviderPublicId(
            providerConfig, providerModel, apiProviderModels(providerConfig).length),
          backendModelId: providerModel.modelId,
          name: providerModel.name || providerModel.modelId,
          serverId: '',
          apiUrl: providerConfig.baseUrl,
          apiKey: providerConfig.apiKey,
          contextSize: Number(providerModel.contextSize) || 0,
          maxOutput: Number(providerModel.maxOutput) || 0,
          pricing: providerModel.pricing || {},
          dailyRequestLimit: Number(providerModel.dailyRequestLimit) ||
            (Number(providerConfig.dailyRequestLimit) || 0),
          tierAccess: Array.isArray(providerConfig.tierAccess)
            ? providerConfig.tierAccess
            : ['free', 'pro', 'vip'],
          enabled: providerConfig.enabled !== false &&
            providerModel.enabled !== false,
          provider: 'external',
        };
      }
    }
    if (!modelConfig) {
      return jsonResponse(request, 404, {
        error: `Model "${wantedModel}" not found.`,
      });
    }
    const modelId = String(modelConfig.modelId);
    // Admin bisa menyembunyikan model: user tidak boleh memakainya sama sekali,
    // walaupun id-nya masih dipegang client (mis. dari cache lama).
    if (modelConfig.enabled === false) {
      return jsonResponse(request, 403, {
        error: `Model "${modelId}" dinonaktifkan admin.`,
      });
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

    // Check tier access
    // FREE model → bisa dipakai siapa saja (token/credit sesuai label model),
    // tanpa restriction tier. MODEL PRO/VIP → cek tier user.
    const userTier = account.tier || config.defaultTier || 'free';
    const allowedTiers = modelConfig.tierAccess || ['free', 'pro', 'vip'];
    const isFreeModel = allowedTiers.includes('free');
    // Model AI lokal (self-hosted / IP private) boleh dipakai siapa saja —
    // user & guest tidak kebagi dulu model lokal, tinggal lewat gateway.
    const selfHosted = isSelfHostedAi(serverConfig, modelConfig);
    if (!selfHosted && isFreeModel) {
      // Model FREE → semua tier boleh gunakan (tanpa restriction).
      // Pembagian token/credit akan diatur berdasarkan label model di bawah.
    } else if (!selfHosted && !isFreeModel && !allowedTiers.includes(userTier)) {
      return jsonResponse(request, 403, {
        error: `Model "${modelId}" requires tier: ${allowedTiers.join(', ')}. Your tier: ${userTier}`,
      });
    }

    // Batas request harian per akun (seperti RPM, tapi per hari). Limit bersifat
    // per akun (tier free default 15, override admin per akun untuk pro/vip) —
    // bukan per model. Hanya dipakai untuk provider eksternal (Provider API):
    // model Local AI / self-hosted pakai aturan lama (token limit + credit)
    // tanpa batas request harian.
    const dailyLimit = providerConfig
      ? accountDailyRequestLimit(config, account)
      : 0;
    if (providerConfig && dailyLimit > 0) {
      const used = await dailyRequestUsed(env, account.id);
      if (used >= dailyLimit) {
        return jsonResponse(request, 429, {
          error: `Batas ${dailyLimit} request/hari untuk akun ini sudah ` +
            'tercapai. Coba lagi besok atau minta admin menaikkan limit.',
          limit: dailyLimit,
          used,
          resetAt: dailyResetAt(),
        });
      }
    }

    // Check balance.
    //
    // Aturan tagihan (sama dengan dashboard & aplikasi):
    //   - harga $0 (semua field 0)          → gratis, potong kuota token
    //   - model FREE + ada harga            → potong kuota token
    //   - model PRO/VIP + ada harga         → SELALU potong kredit
    // Model PRO/VIP berharga TIDAK lagi turun ke mode token saat kredit habis:
    // kalau saldo tidak cukup, request ditolak 402 supaya log dan tagihan tidak
    // tercampur (dulu user diam-diam dipotong token padahal pakai model PRO).
    const pricing = modelConfig.pricing || {};
    const inputPerReq = Number(pricing.inputPerReq) || 0;
    const outputPerReq = Number(pricing.outputPerReq) || 0;
    const inputPer1M = Number(pricing.inputPer1M) || 0;
    const outputPer1M = Number(pricing.outputPer1M) || 0;
    const priced = inputPerReq > 0 || outputPerReq > 0 ||
      inputPer1M > 0 || outputPer1M > 0;
    const useCredits = !isFreeModel && priced;

    if (useCredits) {
      // Biaya per request = flat satu panggilan (input + output /req).
      // Untuk harga /1M, estimasi minimum cukup saldo > 0 karena biaya
      // dihitung setelah jumlah token diketahui.
      const estimatedCost = inputPerReq + outputPerReq;
      const creditBalance = Number(account.creditBalance) || 0;
      if (creditBalance <= 0 || creditBalance < estimatedCost) {
        return jsonResponse(request, 402, {
          error: 'Kredit tidak cukup untuk model ini. Isi saldo kredit atau ' +
            'pakai model gratis (harga $0).',
          required: estimatedCost,
          balance: creditBalance,
          billing: 'credit',
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
          billing: priced ? 'token' : 'free',
        });
      }
    }

    const backendUrl = providerConfig
      ? providerConfig.baseUrl
      : (modelConfig.apiUrl || modelConfig.serverUrl ||
        (serverConfig && serverConfig.baseUrl) || '');
    if (!backendUrl) {
      return jsonResponse(request, 503, { error: 'Backend server URL not configured for this model.' });
    }

    const base = backendUrl.replace(/\/+$/, '');
    const providerTarget = providerConfig
      ? apiProviderTarget(providerConfig, providerModel)
      : null;
    const targetUrl = providerTarget
      ? providerTarget.url
      : (/\/v\d+$/i.test(base)
        ? `${base}/chat/completions`
        : `${base}/v1/chat/completions`);

    // Batasi output sesuai context & max output model (hasil auto-detect
    // `/props`). Ini satu-satunya penentu ukuran jawaban — aplikasi tidak
    // perlu mengirim `max_tokens` sendiri.
    const tokenLimit = resolveMaxTokens(body, modelConfig);
    if (tokenLimit.error) {
      return jsonResponse(request, 413, {
        error: tokenLimit.error,
        promptTokens: tokenLimit.promptEstimate,
        contextSize: tokenLimit.contextSize,
      });
    }

    let headers;
    if (providerConfig) {
      // Provider eksternal: header mengikuti jenis API (Bearer, x-api-key
      // untuk Anthropic native, plus `cf-aig-gateway-id` bila perlu).
      headers = apiProviderHeaders(
        providerConfig, providerTarget.mode, providerModel);
    } else {
      headers = new Headers();
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
    }

    let upstream;
    try {
      const upstreamBody = providerConfig
        ? apiProviderBody(
            providerConfig, providerModel, body, tokenLimit.maxTokens)
        : {
            ...body,
            // Backend selalu menerima nama model asli (bukan id publik
            // `label:model:tier`) dan tanpa folder path.
            model: backendModelName(modelConfig.backendModelId || modelId),
            // Nilai hasil clamp dari context/max output server.
            max_tokens: tokenLimit.maxTokens,
          };
      if (!providerConfig) {
        // Jaga dua nama field tetap sinkron untuk backend OpenAI-compatible
        // baru yang hanya membaca `max_completion_tokens`.
        if (body.max_completion_tokens !== undefined) {
          upstreamBody.max_completion_tokens = tokenLimit.maxTokens;
        }
        // Minta usage di akhir stream supaya kuota tetap terhitung.
        if (body.stream === true) {
          upstreamBody.stream_options = {
            ...(body.stream_options || {}),
            include_usage: true,
          };
        }
      }
      // Hitung request harian per akun tepat sebelum panggilan upstream.
      if (dailyLimit > 0) {
        await bumpDailyRequest(env, account.id);
      }
      upstream = await fetch(targetUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(upstreamBody),
      });
    } catch (error) {
      return jsonResponse(request, 502, { error: `Backend request failed: ${error}` });
    }

    // Streaming (SSE) dinormalisasi ke format OpenAI. Backend llama-server
    // sudah OpenAI-compatible (diteruskan apa adanya); provider eksternal
    // seperti Cloudflare Workers AI mengirim `{response: "..."}` yang
    // dikonversi menjadi delta OpenAI supaya aplikasi tidak perlu diubah.
    if (body.stream === true && upstream.ok && upstream.body) {
      const decoder = new TextDecoder();
      const encoder = new TextEncoder();
      let buffered = '';
      let contentChars = 0;
      let usage = { prompt_tokens: 0, completion_tokens: 0 };
      // llama-server melaporkan `timings.cache_n` (token prompt dari cache KV)
      // di chunk akhir — dasar statistik hit/miss per model.
      let timings = {};
      const tracker = new TransformStream({
        transform(chunk, controller) {
          buffered += decoder.decode(chunk, { stream: true });
          let index;
          while ((index = buffered.indexOf('\n')) >= 0) {
            const line = buffered.slice(0, index).trim();
            buffered = buffered.slice(index + 1);
            if (!line.startsWith('data:')) continue;
            const payload = line.slice(5).trim();
            if (!payload) continue;
            if (payload === '[DONE]') {
              // [DONE] dikirim ulang di flush supaya urutannya selalu
              // sebelum event usage.
              continue;
            }
            let parsed;
            try {
              parsed = JSON.parse(payload);
            } catch (_) {
              // Chunk keep-alive / bukan JSON — abaikan.
              continue;
            }
            if (parsed && parsed.timings) timings = parsed.timings;
            usage = providerSseUsage(parsed, usage);
            // Normalisasi event provider (OpenAI / Anthropic / Workers AI /
            // REST universal) menjadi delta OpenAI. Chunk OpenAI diteruskan
            // apa adanya supaya metadata (finish_reason) tetap utuh.
            for (const event of providerSseChunks(parsed, modelId)) {
              const choice = event.choices && event.choices[0];
              const delta = choice && choice.delta;
              if (delta && typeof delta.content === 'string') {
                contentChars += delta.content.length;
              }
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
            }
          }
        },
        async flush(controller) {
          // Selalu tutup stream dengan [DONE] sebelum event usage.
          try {
            controller.enqueue(encoder.encode('data: [DONE]\n\n'));
          } catch (_) {}
          const cachedTokens = Math.max(0, Number(usage.cached_tokens) || 0) ||
            Math.max(0, Number(timings.cache_n) || 0);
          const promptTokens = Number(usage.prompt_tokens) ||
            (Math.max(0, Number(timings.prompt_n) || 0) + cachedTokens) ||
            estimatePromptTokens(body.messages);
          const completionTokens = Number(usage.completion_tokens) ||
            Number(timings.predicted_n) || Math.ceil(contentChars / 4);
          // Statistik per model: berapa request, berapa prompt yang kena
          // cache, dan berapa token yang dihasilkan.
          const tokensPerSec = Number(timings.predicted_per_second) || 0;
          if (promptTokens > 0 || completionTokens > 0) {
            await recordModelUsage(env, modelId, {
              promptTokens,
              cachedTokens,
              completionTokens,
              tokensPerSec,
            });
          }
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
              encoder.encode(
                'data: ' + JSON.stringify({
                  piercingblow_usage: true,
                  // Mode menentukan mana yang dipotong: token ATAU kredit.
                  mode: useCredits ? 'credit' : 'token',
                  // Batas output yang dipakai gateway (dari context server).
                  maxTokens: tokenLimit.maxTokens,
                  // Kecepatan terkini server (tok/s) untuk model ini.
                  tokensPerSec,
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
      streamHeaders.set('X-Max-Tokens', String(tokenLimit.maxTokens));
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

    // Provider eksternal bisa membalas dengan format non-OpenAI.
    // Cloudflare REST/Workers AI: { success, result: ... }, Anthropic:
    // { content: [{ type: 'text', text }], usage: { input_tokens, ... } }.
    if (providerConfig && responseData) {
      if (responseData.success === false) {
        const firstError = Array.isArray(responseData.errors)
          ? responseData.errors[0]
          : null;
        return jsonResponse(request, 502, {
          error: firstError?.message ||
            'Provider API mengembalikan error.',
        });
      }
      if (responseData.error) {
        const providerError = responseData.error;
        return jsonResponse(request, 502, {
          error: (providerError && providerError.message) ||
            (typeof providerError === 'string' ? providerError
              : 'Provider API mengembalikan error.'),
        });
      }
      responseData = normalizeProviderChatResponse(
        responseData, modelId, estimatePromptTokens(body.messages));
    }

    // Deduct tokens/credits based on usage
    const usage = responseData.usage || {};
    const promptTokens = usage.prompt_tokens || 0;
    const completionTokens = usage.completion_tokens || 0;
    const totalTokens = promptTokens + completionTokens;
    // Statistik prompt cache per model (non-stream).
    const timings = responseData.timings || {};
    if (promptTokens > 0 || completionTokens > 0 || timings.prompt_n) {
      await recordModelUsage(env, modelId, {
        promptTokens: promptTokens ||
          ((Number(timings.prompt_n) || 0) + (Number(timings.cache_n) || 0)),
        cachedTokens: Number(usage.cached_tokens) ||
          Number(timings.cache_n) || 0,
        completionTokens: completionTokens || Number(timings.predicted_n) || 0,
        tokensPerSec: Number(timings.predicted_per_second) || 0,
      });
    }

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
        'X-Max-Tokens': String(tokenLimit.maxTokens),
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
      // Default tampil. Admin bisa menyembunyikan model dari aplikasi.
      enabled: body.enabled !== undefined
        ? !!body.enabled
        : (base.enabled !== false),
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
    // Id dari tab dashboard yang masih lama (`…:free`) tetap harus menghapus
    // entri yang sudah di-retag (`…:pro`) — cocokkan lewat retag juga.
    const filtered = models.filter((m) => m.modelId !== modelId &&
      retagPublicId(m.modelId, m.tierAccess) !== modelId);
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
      // Provider API eksternal (base URL + API key), CRUD admin.
      if (pathname === '/api/admin/api-providers' ||
          pathname.startsWith('/api/admin/api-providers/')) {
        return await handleApiProviders(request, env, pathname);
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