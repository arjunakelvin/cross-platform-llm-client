# PiercingBlow

[![Live Web App](https://img.shields.io/badge/Live_Demo-Try_Web_App-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://ai-chat-orailnoor.web.app/)

A production-ready, cross-platform AI chat client built with Flutter. It unifies local on-device LLM inference (Android) with cloud API access, giving users full control over how their models run.

![Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast](PrivateLM.png)
_Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast_

![Generated on pixel 6 with 20 step](IMG_2390.png)
_Generated on pixel 6 with 20 step_

---

## Daftar Isi

1. [Fitur AI Server Manager (baru)](#fitur-ai-server-manager-baru)
2. [Alur dari nol: VPS → dashboard → aplikasi](#alur-dari-nol-vps--dashboard--aplikasi)
3. [Cara pakai dashboard admin](#cara-pakai-dashboard-admin)
4. [Aturan token vs kredit](#aturan-token-vs-kredit)
5. [API key user (Settings → AI API key)](#api-key-user-settings--ai-api-key)
6. [Gateway AI (OpenAI-compatible)](#gateway-ai-openai-compatible)
7. [Endpoint API](#endpoint-api)
8. [Keamanan](#keamanan)
9. [Menjalankan & menguji lokal](#menjalankan--menguji-lokal)
10. [Deploy ke produksi](#deploy-ke-produksi)
11. [What It Does](#what-it-does)
12. [Technical Architecture](#technical-architecture)
13. [Supported Platforms](#supported-platforms)
14. [Build Configuration](#build-configuration)

---

## Fitur AI Server Manager (baru)

Semua AI server sekarang dikelola per **VPS** (satu kartu = satu VPS), dan
user memakai AI server tersebut lewat **gateway** dengan **API key sendiri**.

| Fitur | Penjelasan |
| --- | --- |
| **Server per VPS** | Tiap VPS punya daemon `manager.py` sendiri. Di dashboard cukup isi **IP + port daemon** + **secret key manager** — Manager URL dibuat otomatis, dan tidak ada lagi input IP/base URL inference atau secret inference. |
| **Deteksi model otomatis** | Saat server disimpan, dashboard memanggil `GET <manager>/servers` dan membaca `apiUrl`, `runtime`, dan daftar model **yang sedang aktif** (AI-nya sudah di-load & jalan) milik VPS itu. Model ID **tidak bisa ditambah manual**. |
| **Model aktif vs nonaktif** | Kalau AI-nya dimatikan, model ditandai **"AI mati"** — harga/tier admin tetap tersimpan, tapi modelnya tidak ditawarkan ke user sampai AI-nya jalan lagi. |
| **Edit per model** | Admin hanya mengedit: nama, tier (free/pro/vip), **harga input/output** (`/req` atau `/1M`), **context size**, dan **max output**. |
| **Monitoring per VPS** | CPU, RAM, Disk, Network (traffic up/down) tiap VPS, plus tombol **Start / Stop / Lihat log** untuk **setiap proses AI** di VPS tersebut. |
| **Gateway OpenAI-compatible** | `POST https://piercingblow.ai.id/api/gateway/v1/chat/completions` dengan `Authorization: Bearer pb_...` (API key milik user). Mendukung streaming (SSE). |
| **API key per akun** | User buat key sendiri di aplikasi (Settings → AI API key). Nilai penuhnya hanya ditampilkan sekali, disimpan terenkripsi di perangkat. |
| **Token & kredit** | Model `$0` memotong kuota token; model `>$0` memotong kredit. Sisa & terpakai tampil real-time di aplikasi. |
| **Log pemakaian** | Tiap request tercatat (akun, model, token, kredit, mode) → tabel **Log pemakaian AI** di dashboard. |
| **Log API key** | Siapa membuat API key tercatat di dashboard (**API Key Logs**). |
| **Cache hit rate** | Statistik cache daftar model 24 jam → tampil di halaman **Settings → AI API key**. |

---

## Alur dari nol: VPS → dashboard → aplikasi

```
┌──────────────┐   GET /manager/servers     ┌────────────────────┐
│  VPS + daemon│ ─────────────────────────► │  Dashboard admin   │
│ manager.py   │   (X-Secret-Key)           │  /admin/           │
│  + AI server │ ◄───────────────────────── │  (X-Admin-Key)     │
└──────┬───────┘   apiUrl, runtime, models  └─────────┬──────────┘
       │                                            │ simpan ke KV
       │                                            ▼
       │                                   ┌────────────────────┐
       │  chat/completions                 │  Cloudflare Worker │
       │  + X-Secret-Key (ditambah worker) │  /api/*             │
       │ ◄──────────────────────────────────│  gateway + config  │
       │                                   └─────────┬──────────┘
       │                                             │ /api/gateway/v1
       │                                             │ (API key user)
       │                                             ▼
       │                                   ┌────────────────────┐
       │                                   │  Aplikasi Flutter   │
       │                                   │  Model List / Chat  │
       └───────────────────────────────────┴────────────────────┘
```

1. Di VPS: jalankan daemon `manager.py` + AI server (Ollama / llama.cpp / vLLM),
   lalu pasang nginx sebagai gerbang secret key.
2. Di dashboard admin: tambah **Manager URL** + **secret key manager** → model,
   statistik, dan tombol start/stop otomatis dari daemon.
3. Di aplikasi: user login Discord → buat **AI API key** → pilih model di tab
   **Model List** → chat. Semua request lewat gateway, jadi user tidak pernah
   memegang secret backend.

Detail daemon & nginx: [`server/README.md`](server/README.md).

---

## Cara pakai dashboard admin

Buka **https://piercingblow.ai.id/admin/** (butuh admin key).

### Tambah VPS

| Kolom | Isi |
| --- | --- |
| **IP / host VPS** | alamat VPS tempat daemon `manager.py` jalan, mis. `203.0.113.10` |
| **Port daemon** | port `manager.py` (default `8788`) |
| **Secret key manager** | nilai `secretKey` di `server/servers.json` VPS itu |
| Manager URL | opsional — **dibuat otomatis** dari IP + port (`http://IP:PORT/manager`); isi manual hanya kalau daemonnya di belakang nginx/path lain |
| Nama / ID / Status / Catatan | opsional |

Tekan **Tambah server & deteksi model**. Setelah tersimpan:

- kartu server menampilkan CPU / RAM / Disk / Net **milik VPS itu**,
- daftar **Proses AI** (Start / Stop / Lihat log) per proses,
- daftar **Model** (otomatis dari daemon) dengan tier, harga, context, max output.

### Edit model

Klik **Edit** pada model → ubah:

- **Tier** yang boleh akses (Free / Pro / VIP),
- **Harga input** & **output**: `$ per request` **atau** `$ per 1M token`
  (kalau `/req` diisi, `/1M` diabaikan untuk sisi itu),
- **Context size** & **Max output**.

> Harga `$0` → pemakaian memotong **kuota token**.
> Harga `>$0` → pemakaian memotong **kredit** akun.

> Model yang AI-nya belum jalan ditandai **"AI mati"**: harga & tier tetap
> disimpan, tapi modelnya tidak muncul di tab Model List pengguna. Nyalakan
> AI-nya (tombol **Start AI** di kartu server), lalu tekan **Deteksi model**
> supaya modelnya aktif lagi.

### Monitoring & log

- Kartu server di-refresh otomatis tiap 6 detik (CPU/RAM/Disk/Network + status proses).
- **Log pemakaian AI (token & kredit)** — semua request + biaya yang dipotong.
- **API Key Logs** — siapa membuat API key.

---

## Aturan token vs kredit

Aturan ditentukan oleh **harga model** yang diatur di dashboard (bukan tier-nya).
Tier hanya menentukan **siapa boleh memakai** model tersebut.

| Harga model | Yang dipotong | Tampilan di aplikasi |
| --- | --- | --- |
| `$0` (per req atau per 1M) | kuota **token** | bar **Kuota Token AI** memendek, "terpakai" naik, "sisa" turun |
| `>$0` | **kredit** | bar **Kredit AI** memendek, "terpakai" naik, "sisa" turun |

Contoh nyata (harga input `$0.0045` per request, saldo awal `$12`):

| Request | Sisa kredit | Terpakai | Token limit |
| --- | --- | --- | --- |
| 0 | `$12` | `$0` | `20,000,000` (tidak berubah) |
| 1 | `$11.9955` | `$0.0045` | `20,000,000` (tidak berubah) |
| 4 | `$11.982` | `$0.018` | `20,000,000` (tidak berubah) |

Semua angka memakai **pemisah ribuan** (`$1,234.5`, `20,000,000`) dan harga
kecil tetap presisi (`$0.0045`).

### Detail di aplikasi (sheet akun)

- **Bar kuota** menampilkan **sisa** kuota (bar memendek saat terpakai), warna
  **hijau menyala → oranye → merah** sesuai level, plus **persentase** di bawah
  bar.
- Kalau kuota habis → tulisan merah **"Kuota token sudah habis. Kuota akan reset
  otomatis sesuai jadwal di atas."**
- Kalau kredit habis → **"Kredit sudah habis…"** (isi di dashboard admin, atau
  pakai model `$0` yang memakai kuota token).
- Angka saldo **langsung turun** begitu chat selesai (dipakai dari header
  `X-Token-Used` / `X-Credit-Used`, atau event `piercingblow_usage` untuk
  streaming) — tidak menunggu sinkronisasi.

---

## API key user (Settings → AI API key)

1. Login Discord di aplikasi.
2. **Settings → AI servers → AI API key**.
3. **Buat API key** → key hanya ditampilkan sekali → **Salin key**.
4. **Tes koneksi** (daftar model + satu chat singkat lewat gateway).
5. **Hapus key** → ditandai terhapus dalam 3 hari (bisa dipakai lagi selama
   masa tenggang).

Key disimpan terenkripsi di perangkat (SecureKeyStore / keystore), tidak
pernah ikut ke server kecuali sebagai hash, dan tidak pernah ditampilkan lagi
setelah ditutup.

---

## Gateway AI (OpenAI-compatible)

Base URL (ditampilkan di aplikasi, **tidak** di dashboard):

```
https://piercingblow.ai.id/api/gateway/v1
```

Contoh:

```bash
curl https://piercingblow.ai.id/api/gateway/v1/models \
  -H "Authorization: Bearer pb_xxxxxxxx"

curl https://piercingblow.ai.id/api/gateway/v1/chat/completions \
  -H "Authorization: Bearer pb_xxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"halo"}]}'
```

- `model` = **model ID publik** (yang tampil di Model List). Kalau nama model
  sama di dua VPS, dashboard memberi prefix: `vps-2/qwen3:8b`.
- Worker memetakan model ID publik → nama model asli di daemon
  (`backendModelId`), lalu meneruskan request ke `apiUrl` VPS tsb dengan
  `X-Secret-Key` backend.
- Streaming (`"stream": true`) diteruskan apa adanya (SSE).

---

## Endpoint API

| Path | Untuk siapa | Auth |
| --- | --- | --- |
| `GET /api/auth/config` | aplikasi (publik) | — (tanpa secret) |
| `GET /api/auth/cache-stats` | aplikasi (publik) | — |
| `GET /api/auth/me` | aplikasi | `Bearer <sesi Discord>` |
| `POST /api/auth/discord` | aplikasi | kode OAuth Discord |
| `POST /api/auth/logout` | aplikasi | `Bearer <sesi Discord>` |
| `GET/POST/DELETE /api/auth/api-key` | aplikasi | `Bearer <sesi Discord>` |
| `GET/POST/PATCH /api/admin/config` | dashboard | `X-Admin-Key` |
| `GET/POST/DELETE /api/admin/accounts[/id]` | dashboard | `X-Admin-Key` |
| `GET/POST/DELETE /api/admin/servers[/id]` | dashboard | `X-Admin-Key` |
| `POST /api/admin/servers/:id/detect-models` | dashboard | `X-Admin-Key` |
| `GET/POST/DELETE /api/admin/server-models[/id]` | dashboard | `X-Admin-Key` |
| `GET /api/admin/usage-logs` | dashboard | `X-Admin-Key` |
| `GET /api/admin/api-key-logs` | dashboard | `X-Admin-Key` |
| `GET /api/bot/verify` | Discord bot | `X-Bot-Key` (**wajib**) |
| `POST /api/bot/sync-tier`, `/api/bot/add-tokens` | Discord bot | `X-Bot-Key` (**wajib**) |
| `GET /api/gateway/models` | aplikasi | `Authorization: Bearer pb_...` |
| `POST /api/gateway/chat/completions` | aplikasi | `Authorization: Bearer pb_...` |
| `GET /api?url=` | proxy CORS provider | hanya target HTTPS publik |

> Endpoint bot **fail-closed**: kalau "Bot API Key" belum diisi di dashboard,
> endpoint-nya mengembalikan 401.

---

## Keamanan

- **Secret backend tidak pernah sampai ke user.** `/api/auth/config` (publik)
  tidak memuat `managerKey`, `apiKey`, atau secret apa pun. Worker yang
  menambahkan `X-Secret-Key` saat meneruskan chat ke VPS.
- **Dashboard admin** (`/api/admin/*`) selalu butuh `X-Admin-Key`.
- **Endpoint bot** selalu butuh `X-Bot-Key`.
- **Gateway** selalu butuh API key user; key dicatat hash-nya saja di KV.
- **Anti open-proxy / SSRF**: `/api?url=` hanya boleh ke target **HTTPS
  publik**; jaringan internal (10.x, 172.16-31.x, 192.168.x, 169.254.x,
  100.64.x, `localhost`, `*.internal`) ditolak, redirect ke host internal
  ditolak, cookie & kunci admin tidak diteruskan, ada batas waktu (120 detik)
  dan batas ukuran respons (32 MB).
- **Route Worker** untuk `/api` polos dipasang eksplisit supaya path itu tidak
  bocor ke origin Vercel.
- **Token admin** dipakai lewat hash-nya di app
  (`AppConstants.adminTokenHash`) — token plaintext tidak pernah disimpan di
  app atau di repo.

---

## Menjalankan & menguji lokal

Butuh Node.js (untuk worker + dev server) dan Flutter (untuk app).

```bash
# 1. Worker + dashboard admin di http://127.0.0.1:8090/admin/  (key: dev-admin-key)
node proxy/dev-server.mjs 8090

# 2. Fake VPS (manager + AI server OpenAI-compatible)
node fake-ai-server.mjs 9101 vps-secret-1 "qwen3:8b,llama3.1:8b"
```

Dev server punya endpoint bantu (hanya lokal, **tidak ada di Worker produksi**):

| Endpoint | Fungsi |
| --- | --- |
| `POST /api/dev/session` | buat akun + sesi uji |
| `POST /api/auth/discord` dengan `code=dev-login[:id]` | login Discord palsu untuk testing |

Tambah server dari dashboard memakai `managerUrl=http://127.0.0.1:9101/manager`
dan secret `vps-secret-1`.

### Test

```bash
flutter analyze     # 0 error, 0 warning
flutter test        # 67 test
```

Test yang relevan:

| File | Isi |
| --- | --- |
| `test/gateway_routing_test.dart` | Local AI memakai gateway + API key user |
| `test/settings_api_key_test.dart` | buat/salin/tes/hapus API key |
| `test/quota_sync_test.dart` | sinkronisasi token & kredit, tanpa dobel hitung |
| `test/quota_bar_test.dart` | bar kuota memendek + berwarna |
| `test/account_sheet_layout_test.dart` | kartu token & kredit (angka ribuan, presisi harga) |

---

## Deploy ke produksi

### Worker (backend)

```powershell
powershell -ExecutionPolicy Bypass -File tools\deploy_worker.ps1
```

Scriptnya: login Cloudflare → cek/bikin KV namespace → set secret `ADMIN_KEY`
→ `wrangler deploy` → verifikasi `/api/admin/health`. Route
`piercingblow.ai.id/api*` ikut terpasang.

> Secret `ADMIN_KEY` **tidak boleh diganti** kalau token admin sudah
> dipublish; hash-nya ada di `lib/core/constants.dart`
> (`AppConstants.adminTokenHash`) dan dipakai untuk cek tool
> `tool/hash_check.dart`.

### Web (build)

```bash
flutter build web --release
```

Hasil build ada di `build/web/` (folder ini **adalah repo git sendiri** dengan
remote ke repo web) dan di-deploy otomatis (Vercel) setelah di-push:

```bash
cd build/web
git add -A && git commit -m "Web: ..." && git push origin main
```

Jangan lupa salin `web/admin/index.html` → `build/web/admin/index.html` dan
`web/api/index.js` → `build/web/api/index.js` setelah build.

---

## What It Does

- **Local Inference on Android** — Download and run GGUF models directly on your phone using GPU-accelerated inference (Vulkan). No internet required after download.
- **Cloud API Fallback** — Seamlessly switch to OpenAI, Anthropic, Google Gemini, or Kimi (Moonshot AI) when you need more power or are on unsupported platforms.
- **AI Server Manager** — Kelola banyak VPS AI dari dashboard admin: monitor CPU/RAM/disk/network, start/stop per proses, atur tier & harga per model, dan sajikan lewat gateway + API key per user.
- **Multimodal Chat** — Send text and images in conversations. Vision support works with both local models (Qwen2-VL) and cloud providers.
- **Persistent Sessions** — All chats and settings are stored locally via Hive. Nothing leaves your device unless you explicitly choose cloud mode.
- **Background Services** — Firebase Cloud Messaging integration for push updates and background task handling.
- **Smart Auto-Configuration** — On first launch, the app detects your device's RAM and recommends optimal context size and token limits automatically.
- **Task Management (in development)** — A task view for structured, multi-step AI workflows is being built. It is not available in the app yet.

---

## Technical Architecture

### Stack

- **Framework:** Flutter 3.x (Dart >=3.3.0)
- **State Management:** GetX
- **Local Storage:** Hive
- **Networking:** Dio + `package:http`
- **Background Execution:** `flutter_background_service` + `flutter_local_notifications`
- **Push Notifications:** Firebase Core + Firebase Messaging
- **Backend:** Cloudflare Worker (`proxy/cloudflare-worker.js`) + KV

### Struktur folder penting

| Folder/berkas | Isi |
| --- | --- |
| `proxy/` | Worker (API, gateway, dashboard admin logic) + `dev-server.mjs` untuk lokal |
| `server/` | daemon `manager.py` (Python 3, tanpa dependency) + contoh nginx |
| `web/admin/index.html` | dashboard admin (privat, butuh admin key) |
| `web/api/` | forwarder Vercel + proxy CORS (hardened) |
| `build/web/` | hasil build web (repo git sendiri, target deploy) |

### Inference Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / ModelView / ServerView / SettingsView          │
└──────────────────────────┬──────────────────────────────────┘
                            │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · TaskController · ModelController         │
│   SettingsController · HomeController                       │
└──────────────────────────┬──────────────────────────────────┘
                            │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (OpenAI/Claude/ │  │ (model dl)  │ │
│  │                 │  │  Gemini/Kimi)   │  │             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ExecutionSvc │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (bg tasks)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │DashboardConfig  │  │  DiscordService │  │ SecureKey   │ │
│  │ (server+model)  │  │  (login/tier)   │  │  Store      │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Local Inference (Android)

The app uses `llama_flutter_android`, a custom Flutter plugin wrapping `llama.cpp` for ARM64 devices. At runtime it:

1. **Detects GPU capabilities** via Vulkan to determine offload layers.
2. **Selects thread count** based on device tier (ultra / high / mid / low).
3. **Loads the GGUF model** with progress streaming.
4. **Generates tokens** via `generateChat()` with native chat-template support (ChatML, Llama-3, Gemma, Phi).
5. **Falls back** to manual prompt construction if native templates fail.

Idle detection (5s) and hard timeouts (180s) keep the UX responsive even on underpowered hardware.

### Cloud Inference

`CloudService` normalizes four different API shapes into a single interface:

- **OpenAI** — standard `/v1/chat/completions`
- **Anthropic** — Messages API with separate system param
- **Google Gemini** — `generateContent` with inline image base64
- **Kimi** — OpenAI-compatible endpoint from Moonshot AI

Plus provider **Local AI** yang mengarah ke gateway milik sendiri (pakai API key
user, bukan secret backend).

API keys are stored in Hive and never transmitted anywhere except to the provider's endpoint.

### Backend Worker (API + dashboard admin)

`proxy/cloudflare-worker.js` (Cloudflare Worker) melayani:

| Path | Untuk siapa | Auth |
| --- | --- | --- |
| `/api/admin/*` | dashboard admin | header `X-Admin-Key` |
| `/api/bot/*` | Discord bot | header `X-Bot-Key` (**wajib**; kalau "Bot API Key" kosong di dashboard, endpoint-nya ditutup) |
| `/api/auth/*` | aplikasi | sesi Discord (token), kecuali `/api/auth/config` yang publik |
| `/api/gateway/v1/*` | aplikasi (API key user) | `Authorization: Bearer pb_...` |
| `/api?url=` | proxy CORS untuk provider | hanya target HTTPS publik (jaringan internal/metadata ditolak) |

### Server Manager (AI server remote)

Semua AI server dikelola dari **dashboard admin privat**
(`https://piercingblow.ai.id/admin/` → kartu **Server manager**):

- daftar server AI (per VPS) + model yang tersedia di tiap server,
- nyalakan / matikan AI **per proses** di VPS tersebut,
- status CPU, RAM, penyimpanan, dan jaringan (di-refresh otomatis),
- log sederhana (kapan server dinyalakan, output runtime terakhir).

Request dari web client selalu membawa header `X-Secret-Key` (di-gerbang
nginx), jadi server AI hanya menerima request yang memang hdr-authorized —
tanpa secret, request tidak dikirim sama sekali.

Backend-nya ada di [`server/`](server/README.md) — daemon Python 3 tanpa
dependency + contoh nginx yang menjadi gerbang secret key:

```bash
cp server/servers.json.example server/servers.json   # isi secretKey + apiUrl
python3 server/manager.py --config server/servers.json
```

Di aplikasi, provider **Local AI** memakai model dari dashboard (tab
**Model List**) dan request-nya lewat gateway memakai API key user.

### Web admin & domain

- Dashboard admin privat: **https://piercingblow.ai.id/admin/** (tidak
  ditautkan dari app).
- `www.piercingblow.ai.id` **tidak punya record DNS** — selalu pakai apex
  `piercingblow.ai.id`.
- API backend (`/api/admin/*`, `/api/auth/*`, `/api/bot/*`, `/api/gateway/*`)
  hidup di Cloudflare Worker; situsnya di Vercel. Supaya tidak ketelan rewrite
  `"/api/(.*)"` (yang bikin error `Missing target URL in query parameter
  "url"`), repo ini sudah punya `web/api/worker.js` sebagai forwarder ke
  Worker — set env `WORKER_URL` di project Vercel, atau pasang route Worker
  `piercingblow.ai.id/api*` di Cloudflare. Detailnya di
  [`proxy/README.md`](proxy/README.md).

### Cross-Platform Abstraction

Local inference is conditionally compiled:

- **Android** → `inference_android.dart` (full llama.cpp engine)
- **Web** → `inference_stub.dart` (cloud-only, local coming soon)
- **iOS** → `inference_android.dart` (full llama.cpp engine via Metal GPU)

The `InferenceService` exposes `supportsLocalInference` so the UI can hide local-model UI on unsupported platforms.

---

## Supported Platforms

| Platform | Local Inference | Cloud APIs | Notes                           |
| -------- | --------------- | ---------- | ------------------------------- |
| Android  | ✅ Yes          | ✅ Yes     | CPU offload via NEON; minSdk 28 |
| iOS      | ✅ Yes          | ✅ Yes     | Metal GPU acceleration          |
| Web      | ❌ No           | ✅ Yes     | Cloud-only (local coming soon)  |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/orailnoor/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `PrivateLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, PrivateLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

*Note: Sideloaded apps via AltStore expire after 7 days, but AltStore will attempt to automatically refresh them in the background when connected to the same Wi-Fi as your computer running AltServer.*

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0
- Android SDK (API 26+)
- JDK 17
- NDK (bundled with Android SDK)
- Node.js (untuk Worker & dev server)

### Android

```bash
flutter pub get
flutter build apk --debug
```

Release APKs require a stable signing key. Copy
`android/key.properties.example` to `android/key.properties`, fill in the
keystore values, and keep both the key and its backup. Android accepts an APK
upgrade only when it is signed with the same key as the installed APK.

```bash
cp android/key.properties.example android/key.properties
flutter build apk --release --split-per-abi
```

Never rotate the signing key between GitHub releases. The per-ABI APKs must
also keep increasing the build number in `pubspec.yaml`.

### iOS

```bash
flutter pub get
cd ios
pod install
flutter build ios
```

### Web

```bash
flutter pub get
flutter build web --release
```

---

## License

MIT — see [LICENSE](./LICENSE) for details.
