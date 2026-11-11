# Server Manager — backend AI server untuk web client

Folder ini berisi backend yang dipakai layar **Server manager** di web client
PiercingBlow (Settings → AI servers → Server manager).

```
server/
├── manager.py                  # daemon manager (Python 3, tanpa dependency)
├── servers.json.example        # contoh config: server AI + secret key
└── nginx-ai-server.conf.example# contoh nginx: gerbang secret key
```

## Alur singkat

1. **Admin dashboard** (`https://piercingblow.ai.id/admin/`) → kartu
   **Server manager & model AI**.
2. Satu kartu = satu VPS. Isi **Manager URL** daemon Python
   (`https://api-ai.domainkamu.com/manager`) + **Secret key manager**
   (nilai `secretKey` di `servers.json` VPS itu). Tidak perlu lagi mengisi
   IP/base URL inference atau secret inference.
3. Saat disimpan, dashboard memanggil `GET <manager>/servers` dan membaca
   `apiUrl`, `runtime`, dan daftar `models` milik VPS tersebut. Semua model
   yang ada otomatis terdaftar — admin **hanya mengedit** harga, tier,
   context, dan max output (model ID tidak bisa ditambah manual).
4. Kartu server menampilkan CPU / RAM / Disk / Network per VPS, daftar proses
   AI di VPS itu (Start / Stop / Log tiap proses).
5. Aplikasi web menarik daftar server + model dari `/api/auth/config` dan
   menampilkannya di tab **Model List** / provider **Local AI**. Secret key
   backend tidak pernah dikirim ke browser user.

## 1. Jalankan daemon

```bash
cp server/servers.json.example server/servers.json
# edit server/servers.json: ganti secretKey, apiUrl, startCommand

python3 server/manager.py --config server/servers.json
# [manager] listen di http://127.0.0.1:8788 (2 server terdaftar)
```

systemd unit sederhana (`/etc/systemd/system/pb-manager.service`):

```ini
[Unit]
Description=PiercingBlow Server Manager
After=network.target

[Service]
WorkingDirectory=/opt/piercingblow
ExecStart=/usr/bin/python3 server/manager.py --config /opt/piercingblow/server/servers.json
Restart=always

[Install]
WantedBy=multi-user.target
```

## 2. Pasang nginx (gerbang secret key)

```bash
cp server/nginx-ai-server.conf.example /etc/nginx/sites-available/api-ai
# ganti server_name + secret key di dalamnya
ln -s /etc/nginx/sites-available/api-ai /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Semua request — inference maupun manager — wajib membawa header
`X-Secret-Key`. Tanpa itu: `403 Akses Ditolak!`.

> Secret yang dipakai untuk `/manager` **sama** dengan yang dipakai untuk
> inference, jadi satu secret per VPS cukup. Worker memakai secret itu saat
> meneruskan chat ke backend, sehingga user tidak perlu punya secret backend.

## 3. Tambah VPS dari admin dashboard

Buka `https://piercingblow.ai.id/admin/` → kartu **Server manager & model AI**.

1. Isi **Manager URL** daemon Python di VPS tersebut
   (contoh `https://api-ai.domainkamu.com/manager`) dan **Secret key
   manager** yang sama dengan `secretKey` di `servers.json` VPS itu.
2. Tekan **Tambah server & deteksi model**. Ulangi untuk VPS kedua, ketiga,
   dan seterusnya — tiap VPS punya Manager URL + secret sendiri sehingga
   model, CPU/RAM, dan traffic-nya dipantau terpisah.
3. Model langsung terisi dari daemon. Tekan **Edit server** untuk mengubah
   nama/tier/harga/context/max output tiap model, atau **Deteksi model**
   untuk mengambil ulang daftar model dari daemon.
4. Di kartu server, tiap proses AI punya tombol **Start AI**, **Stop**, dan
   **Lihat log**.

Daftar server + model ini disimpan di Worker (KV) dan otomatis dibaca
aplikasi web lewat `/api/auth/config` (tanpa membocorkan secret key backend).
Tab **Model List** di halaman Models hanya menampilkan model yang benar-benar
terdaftar di dashboard dan sesuai tier akun.

> `server/servers.json` hanya dipakai daemon untuk start/stop proses dan
> statistik CPU/RAM/log — bukan tempat mengatur model atau pricing lagi.

## 4. API key user (gateway)

User membuat API key sendiri di aplikasi: **Settings → AI API key**.

- `POST /api/auth/api-key` — buat key (nilainya hanya ditampilkan sekali).
- `GET /api/auth/api-key` — cek key aktif (prefix saja).
- `DELETE /api/auth/api-key` — tandai untuk dihapus (aktif lagi 3 hari).
- Base URL gateway: `<origin>/api/gateway/v1` (OpenAI-compatible).
  Contoh: `curl https://piercingblow.ai.id/api/gateway/v1/chat/completions \
    -H "Authorization: Bearer pb_xxx" -d '{"model":"qwen3:8b","messages":[...]}'`

Model dengan harga `$0` memotong kuota token; model dengan harga di atas
`$0` memotong kredit akun. Pemakaian tercatat di log pemakaian admin
dashboard.

## 5. Cek cepat

```bash
curl -i https://api-ai.domainkamu.com/manager/servers \
  -H "X-Secret-Key: KUNCIMU"
# 200 → {"servers":[{"id":"ollama-main","running":true,...}]}
# 403 → secret key tidak cocok / header tidak dikirim
```

## Catatan config `servers.json`

| Field | Keterangan |
| --- | --- |
| `secretKey` | Wajib. Dipakai sebagai `X-Secret-Key` (manager + inference). |
| `listen.host/port` | Alamat daemon manager (default `127.0.0.1:8788`, di belakang nginx). |
| `servers[].id` | ID unik, dipakai di URL. |
| `servers[].apiUrl` | URL publik server AI (base OpenAI-compatible, mis. `https://api-ai.domainkamu.com/v1`). Dibaca dashboard untuk request chat ke VPS ini. |
| `servers[].port` | Port lokal runtime; dipakai untuk deteksi "running". |
| `servers[].models` | Daftar model yang tersedia (dibaca dashboard → dideteksi otomatis). |
| `servers[].startCommand` | Perintah untuk menyalakan runtime. |
| `servers[].stopCommand` | (opsional) Perintah untuk mematikan runtime. |
| `servers[].env` | (opsional) Environment tambahan, mis. `CUDA_VISIBLE_DEVICES`. |
| `servers[].logFile` | (opsional) Log runtime ditulis ke file ini juga. |

Beberapa AI sekaligus bisa dinyalakan bersamaan — masing-masing punya port
dan `apiUrl` sendiri, dan web client bisa memilih salah satunya untuk
provider "AI Local".
