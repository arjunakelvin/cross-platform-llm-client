# Proxy CORS + backend auth/admin untuk custom provider & login Discord

Worker di `cloudflare-worker.js` sekarang punya dua tugas:

1. **Proxy CORS** untuk gateway OpenAI-compatible (`/api?url=...`).
2. **Backend auth + admin**: login Discord (OAuth), akun dengan tier, dan
   konfigurasi yang dikelola dari dashboard admin privat di `/admin/`.

## Deploy backend (sekali saja)

Cara paling mudah pakai [wrangler](https://developers.cloudflare.com/workers/wrangler/):

```bash
cd proxy
wrangler kv namespace create PB_KV
# salin id yang muncul ke wrangler.toml (binding PB_KV)
wrangler secret put ADMIN_KEY
# masukkan kunci admin rahasia — ini yang diketik di dashboard /admin/
wrangler deploy
```

Lalu di Cloudflare Dashboard → Workers → Triggers, tambahkan route:

```
piercingblow.ai.id/api*
```

> **Pakai apex, bukan `www`.** Host `www.piercingblow.ai.id` tidak punya
> record DNS (hanya `piercingblow.ai.id` yang resolve), jadi route `www`
> tidak akan pernah kena. Kalau ingin `www` ikut jalan, tambahkan record
> CNAME `www` → apex di DNS Cloudflare lebih dulu.

(zone `piercingblow.ai.id`). Tanpa wrangler: buat Worker di dashboard, salin
isi `cloudflare-worker.js`, buat KV namespace dan bind sebagai `PB_KV`,
tambah secret `ADMIN_KEY`, lalu pasang route di atas.

## Domain & routing (penting)

Situs `piercingblow.ai.id` di-host di **Vercel**, API backend di
**Cloudflare Worker**. Dua hal yang sering bikin dashboard admin gagal:

1. **`www` tidak ada.** Hanya apex yang resolve.
2. **Rewrite Vercel menelan `/api/*`.** `web/vercel.json` me-rewrite semua
   `/api/*` ke proxy CORS (`web/api/index.js`), sehingga
   `/api/admin/health` dijawab `Missing target URL in query parameter "url"`
   dan dashboard admin tidak pernah sampai ke Worker.

Perbaikannya sudah ada di repo:

- `web/api/[...path].js` meneruskan `/api/<path>` ke Worker
  (env `WORKER_URL` di project Vercel), sehingga `/api/admin/*`,
  `/api/auth/*` (login Discord) dan `/api/bot/*` sampai ke backend.
- `web/vercel.json` tidak lagi me-rewrite `/api/admin`, `/api/auth`,
  `/api/bot` ke proxy CORS.

Dua cara menyalakannya (pilih salah satu):

| Cara | Yang perlu dilakukan | Catatan |
| --- | --- | --- |
| **A. Route di Cloudflare (disarankan)** | `wrangler deploy` dengan `routes` di `wrangler.toml` | Request `/api/*` Handle di edge Cloudflare, tidak menyentuh Vercel. `WORKER_URL` tidak perlu diset. |
| **B. Forward lewat Vercel** | Deploy Worker ke `workers.dev`, set env `WORKER_URL` di project Vercel | Zyanya perlu satu variabel env tambahan. |

Cek cepat setelah deploy:

```bash
curl -i https://piercingblow.ai.id/api/admin/health -H "X-Admin-Key: <ADMIN_KEY>"
# 200 {"ok":true,...}          -> Worker hidup & ADMIN_KEY cocok
# 503 ADMIN_KEY is not set...  -> secret belum diset di Worker
# 503 WORKER_URL is not set... -> pakai cara B, set env di Vercel
```

## Kalau dashboard admin tidak bisa masuk

Turutan cepat:

1. **Cek "Worker URL" di halaman login.** Kalau `/api` di domain masih
   ketahan proxy CORS, isi alamat Worker Cloudflare
   (`https://piercingblow-api.<subdomain>.workers.dev`) — dashboard akan
   langsung menembak Worker dari browser (CORS sudah diizinkan worker untuk
   origin `piercingblow.ai.id`). Field ini disimpan di localStorage.
2. **Pesan error yang muncul:**
   - `Missing target URL in query parameter "url"` → rewrite Vercel masih
     menelan `/api/*`. Pakai cara A (route Cloudflare) atau set `WORKER_URL`.
   - `ADMIN_KEY is not set on the worker` → jalankan
     `wrangler secret put ADMIN_KEY` lalu `wrangler deploy`.
   - `Invalid admin key` → key yang diketik beda dengan `ADMIN_KEY`.
   - `Failed to fetch` → "Worker URL" salah / tidak ada DNS.

## Proxy CORS (dipakai otomatis di web)

Endpoint `https://piercingblow.ai.id/api?url=<target>` meneruskan request ke
`<target>` dan menambahkan header CORS. Di web, app memakainya otomatis untuk:

- provider **Custom** (base URL + API key sendiri, mis. wusrouter),
- provider **AI Local** (server AI di VPS),
- mengambil daftar model (`/models`).

Header yang diteruskan: `Authorization`, `Content-Type`, `Accept`, dan
`X-Secret-Key` (untuk AI server yang digerbang nginx). Target harus HTTPS
(kecuali localhost).

## Yang bisa diatur dari dashboard

| Field | Dipakai untuk |
| --- | --- |
| AI server URL | alamat provider **AI Local** (`aiServerUrl`) — dibaca semua app saat startup |
| Secret key AI server | dikirim aplikasi sebagai header `X-Secret-Key` + `Authorization: Bearer` (`localCloudKey`) |
| Server manager URL | alamat API Server Manager (`managerUrl`) |
| Secret key manager | `X-Secret-Key` untuk API manager (`managerSecretKey`) |

Semuanya ikut dibaca aplikasi saat startup **dan** bisa ditarik ulang dari
layar **Settings → AI servers → Server manager → Tarik dari dashboard**.


## Dashboard admin privat

- Link: `https://piercingblow.ai.id/admin/`
  (file `web/admin/index.html` ikut ter-build; **tidak ditautkan dari app**).
- Login memakai `ADMIN_KEY` yang diset saat deploy. Key ini hanya ada di
  Worker — tidak pernah disimpan di app (app hanya menyimpan SHA-256 hash)
  dan tidak pernah dikirim ke browser user.
- Semua request dari dashboard memakai header `X-Admin-Key`.
- Yang bisa diatur:
  - **Login Discord**: on/off, Client ID, Client Secret (disimpan di server,
    tidak pernah dikirim ke browser user), Redirect URI.
  - **Tier**: daftar tier, tier default akun baru, saldo token default.
  - **Server AI lokal**: URL + API key yang dibaca semua app saat startup.
  - **Akun**: role (user/admin), tier, saldo token/kredit, ban, hapus.
    Akun otomatis dibuat saat user login Discord pertama kali.

Di Discord Developer Portal (OAuth2 → Redirects), daftarkan redirect URI
yang sama dengan yang diisi di dashboard, mis. `https://www.piercingblow.ai.id/`.

## Uji lokal tanpa deploy

```bash
flutter build web --release
node proxy/dev-server.mjs 8090
```

Buka `http://localhost:8090/admin/` — admin key lokal: `dev-admin-key`.
Data disimpan di memori (hilang saat server berhenti). Jangan dipakai untuk
produksi.

Regression test Worker (API key, sesi, gateway) tanpa perlu deploy:

```bash
node --test proxy/api-key.test.mjs
```

## Kenapa perlu proxy?

Saat aplikasi berjalan di browser (web), browser hanya mengizinkan request ke
domain lain kalau server tujuan mengirim header `Access-Control-Allow-Origin`
(CORS). Banyak gateway OpenAI-compatible — termasuk **WusRouter**
(`https://wusrouter.com/v1`) — tidak mengirim header itu, sehingga browser
memblokir request dan `package:http` melaporkan:

```
ClientException: Failed to fetch
```

Ini bukan salah base URL atau API key. Aplikasi desktop/mobile tidak terkena
CORS karena tidak berjalan di browser. Solusi untuk web adalah memakai proxy
milik sendiri.

## Opsi 1 — Cloudflare Worker (untuk domain piercingblow.ai.id)

DNS domain ini sudah lewat Cloudflare, jadi cara paling mudah:

1. Buka **Cloudflare Dashboard → Workers & Pages → Create → Worker**.
2. Salin isi [`cloudflare-worker.js`](cloudflare-worker.js) ke editor Worker.
3. Deploy, lalu buka **Settings → Triggers → Add route**.
4. Tambahkan route:

   ```
   www.piercingblow.ai.id/api*
   ```

   (sesuaikan zone `piercingblow.ai.id`).

5. Di aplikasi: **Browse → Cloud → Custom API**, isi **Base URL**
   `https://wusrouter.com/v1`, API key, dan Model. **Proxy URL boleh
   dikosongkan** — aplikasi otomatis memakai proxy di `/api` pada domain
   yang sama (`https://www.piercingblow.ai.id/api?url=`).

   Kalau ingin eksplisit, isi Proxy URL:

   ```
   https://www.piercingblow.ai.id/api?url=
   ```

Worker akan meneruskan request ke endpoint asli dan menambahkan header CORS,
termasuk untuk streaming SSE.

> Kalau situs di-host di Cloudflare Pages, Worker juga bisa dipakai sebagai
> route pada zone yang sama; tidak perlu mengubah origin.

## Opsi 2 — Proxy lokal (untuk development)

```powershell
C:\flutter\flutter\bin\cache\dart-sdk\bin\dart.exe run proxy/local_proxy.dart 8787
```

Lalu isi Proxy URL di aplikasi dengan:

```
http://localhost:8787/?url=
```

Jangan membuka proxy ini ke internet publik: siapa pun bisa memakainya untuk
meneruskan request lewat mesin Anda.

## Format Proxy URL

- Kosong → **otomatis**: coba koneksi langsung dulu, lalu proxy bawaan di
  `/api` pada origin aplikasi (`https://<domain>/api?url=`). Di aplikasi
  non-web, kosong berarti koneksi langsung.
- `https://proxy.example.com/?url=` → endpoint asli ditambahkan sebagai
  parameter `url` (di-encode otomatis).
- `https://proxy.example.com/{url}` → placeholder diganti endpoint ter-encode.

## Keamanan

- API key hanya dikirim dari browser ke proxy dan diteruskan ke penyedia;
  jangan memakai proxy publik pihak ketiga untuk key berbayar.
- Worker sengaja tidak meneruskan cookie, `Origin`, atau header `CF-*`.
