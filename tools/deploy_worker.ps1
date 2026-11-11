<#
  Deploy Cloudflare Worker PiercingBlow + set ADMIN_KEY + route di domain.

  Pakai:
      powershell -ExecutionPolicy Bypass -File tools\deploy_worker.ps1
      powershell -ExecutionPolicy Bypass -File tools\deploy_worker.ps1 -AdminKey "tokenmu"

  Yang dilakukan:
    1. cek Node.js + wrangler (npx otomatis download)
    2. login Cloudflare (kalau belum, buka link yang muncul di browser)
    3. buat KV namespace PB_KV (kalau wrangler.toml masih placeholder)
    4. set secret ADMIN_KEY
    5. deploy (route piercingblow.ai.id/api* ikut terpasang dari wrangler.toml)
    6. cek hasilnya

  File ini sengaja ASCII-only supaya aman di PowerShell 5.1.
#>
param(
    [string]$AdminKey = 'pb_admin_35ef34ae454a51311db656b321117bb8b47dc734',
    [string]$Zone = 'piercingblow.ai.id'
)

$ErrorActionPreference = 'Continue'
$proxyDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'proxy'
Set-Location $proxyDir

function Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

# ── Node.js ──────────────────────────────────────────────────────────────
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    $portable = Join-Path $env:LOCALAPPDATA 'Temp\opencode\node\node-v22.14.0-win-x64\node.exe'
    if (Test-Path $portable) {
        $env:PATH = (Split-Path -Parent $portable) + ';' + $env:PATH
        $node = $portable
    }
}
if (-not $node) {
    Write-Host 'Node.js tidak ditemukan.' -ForegroundColor Yellow
    Write-Host 'Pasang Node.js LTS dari https://nodejs.org lalu jalankan lagi.' -ForegroundColor Yellow
    exit 1
}
Write-Host "node: $node"

# ── Login ────────────────────────────────────────────────────────────────
Head 'Login Cloudflare'
npx --yes wrangler@latest whoami 2>&1 | Select-Object -First 4
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Belum login. Buka link ini di browser dan Allow:' -ForegroundColor Yellow
    Write-Host '  https://dash.cloudflare.com/workers' -ForegroundColor Yellow
    npx --yes wrangler@latest login
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Login gagal / dibatalkan.' -ForegroundColor Red
        exit 1
    }
}

# ── KV namespace ─────────────────────────────────────────────────────────
Head 'KV namespace PB_KV'
$toml = Get-Content 'wrangler.toml' -Raw
if ($toml -match 'ISI_DENGAN_ID_KV_NAMESPACE') {
    Write-Host 'Membuat KV namespace...'
    $out = (npx --yes wrangler@latest kv namespace create PB_KV 2>&1 | Out-String)
    Write-Host $out
    if ($out -match 'id\s*=\s*"([a-f0-9]+)"') {
        $kvId = $Matches[1]
        (Get-Content 'wrangler.toml' -Raw) -replace 'ISI_DENGAN_ID_KV_NAMESPACE', $kvId |
            Set-Content 'wrangler.toml'
        Write-Host "KV id ditulis ke wrangler.toml: $kvId" -ForegroundColor Green
    } else {
        Write-Host 'Gagal membaca id KV namespace. Isi manual di wrangler.toml.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'KV namespace sudah terisi.'
}

# ── Secret ADMIN_KEY ─────────────────────────────────────────────────────
Head 'Secret ADMIN_KEY'
$AdminKey | npx --yes wrangler@latest secret put ADMIN_KEY

# ── Deploy ───────────────────────────────────────────────────────────────
Head 'Deploy'
npx --yes wrangler@latest deploy
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Deploy gagal.' -ForegroundColor Red
    exit 1
}

# ── Verify ───────────────────────────────────────────────────────────────
Head 'Cek hasil'
$out = & curl.exe -s -o - -w "`n__STATUS__%{http_code}" `
    "https://$Zone/api/admin/health" -H "X-Admin-Key: $AdminKey" 2>$null
$text = ($out -join "`n")
$status = 0
if ($text -match '__STATUS__(\d{3})') { $status = [int]$Matches[1] }
$body = ($text -replace "`n__STATUS__\d{3}$", '').Trim()
Write-Host "HTTP $status $body"
if ($status -eq 200) {
    Write-Host 'SIAP. Dashboard: https://piercingblow.ai.id/admin/' -ForegroundColor Green
} else {
    Write-Host 'Belum OK. Cek pesan di atas.' -ForegroundColor Yellow
}
