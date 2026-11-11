<#
  Cek cepat apakah dashboard admin bisa dipakai.

  Pakai:
      powershell -ExecutionPolicy Bypass -File tools\cek_admin.ps1
      powershell -ExecutionPolicy Bypass -File tools\cek_admin.ps1 -AdminKey "tokenmu"
      powershell -ExecutionPolicy Bypass -File tools\cek_admin.ps1 -Domain api-ai.domainmu.com

  Output-nya bakal nunjukin tepat salahnya di mana:
      - DNS domain / www
      - apakah /api/* sampai ke Worker atau masih ketelan proxy Vercel
      - apakah ADMIN_KEY sudah di-set di Worker
      - apakah key yang dipakai cocok

  Catatan: file ini sengaja ASCII-only supaya aman dijalankan di
  PowerShell 5.1 (Windows).
#>
param(
    [string]$AdminKey = '',
    [string]$Domain = 'piercingblow.ai.id'
)

function Head($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }

function Fetch($url, $key) {
    $args = @('-s', '-o', '-', '-w', "`n__STATUS__%{http_code}", $url)
    if ($key) { $args += @('-H', "X-Admin-Key: $key") }
    $raw = & curl.exe @args 2>$null
    $text = ($raw -join "`n")
    $status = 0
    if ($text -match '__STATUS__(\d{3})') { $status = [int]$Matches[1] }
    $body = ($text -replace "`n__STATUS__\d{3}$", '').Trim()
    return @{ Status = $status; Body = $body }
}

Head "DNS"
foreach ($name in @($Domain, "www.$Domain")) {
    try {
        $ip = (Resolve-DnsName $name -ErrorAction Stop |
                Where-Object { $_.IPAddress } |
                Select-Object -First 1 -ExpandProperty IPAddress)
        Write-Host "  $name -> $ip"
    } catch {
        Write-Host "  $name -> TIDAK ADA (DNS belum diset / hostname salah)" -ForegroundColor Yellow
    }
}

Head "Worker (api/admin/health)"
$res = Fetch "https://$Domain/api/admin/health" $AdminKey
Write-Host "  HTTP $($res.Status) $($res.Body)"
if ($res.Status -eq 200) {
    Write-Host "  -> Worker hidup dan ADMIN_KEY cocok." -ForegroundColor Green
    Write-Host "  Dashboard: https://$Domain/admin/" -ForegroundColor Green
} elseif ($res.Body -match 'Missing target URL') {
    Write-Host "  -> /api masih diteruskan ke proxy CORS Vercel." -ForegroundColor Yellow
    Write-Host "     Deploy Worker dengan route piercingblow.ai.id/api* :" -ForegroundColor Yellow
    Write-Host "       cd proxy; npx wrangler secret put ADMIN_KEY; npx wrangler deploy" -ForegroundColor Yellow
    Write-Host "     atau set env WORKER_URL di project Vercel (web\api\[...path].js)." -ForegroundColor Yellow
} elseif ($res.Body -match 'ADMIN_KEY is not set') {
    Write-Host "  -> Worker belum punya ADMIN_KEY:" -ForegroundColor Yellow
    Write-Host "       cd proxy; npx wrangler secret put ADMIN_KEY" -ForegroundColor Yellow
} elseif ($res.Body -match 'Invalid admin key') {
    Write-Host "  -> ADMIN_KEY tidak cocok dengan yang dipakai dashboard." -ForegroundColor Yellow
} elseif ($res.Status -eq 401 -or $res.Status -eq 403) {
    Write-Host "  -> Request ditolak. Cek ADMIN_KEY." -ForegroundColor Yellow
} else {
    Write-Host "  -> Worker tidak terjangkau. Cek DNS / route / firewall." -ForegroundColor Yellow
}

Head "Halaman dashboard"
$page = Fetch "https://$Domain/admin/" ''
if ($page.Status -eq 200) {
    Write-Host "  HTTP 200, $($page.Body.Length) byte"
    if ($page.Body -match 'Worker URL') {
        Write-Host "  Versi dashboard: BARU (ada field Worker URL + Server manager)" -ForegroundColor Green
    } else {
        Write-Host "  Versi dashboard: LAMA (belum ada field Worker URL)" -ForegroundColor Yellow
        Write-Host "  Deploy ulang web: jalankan build_web_deploy.bat lalu deploy build\web ke Vercel." -ForegroundColor Yellow
    }
} else {
    Write-Host "  HTTP $($page.Status) - halaman admin tidak terbaca" -ForegroundColor Yellow
}
