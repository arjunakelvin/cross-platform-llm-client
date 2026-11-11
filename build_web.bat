@echo off
setlocal EnableExtensions
title PrivateLM - Build Ulang Web (build saja)

rem ============================================================
rem  Build ulang Flutter Web (release) SAJA.
rem  - Tidak menyalakan web server (Caddy)
rem  - Tidak membuka browser
rem  - Tidak perlu hak Administrator
rem  - Hasil build : build\web
rem  - Butuh Flutter SDK di C:\flutter_sdk\flutter
rem ============================================================

set "FLUTTER_BIN=C:\flutter_sdk\flutter\bin"
set "PROJECT=%~dp0"

echo ============================================
echo    PrivateLM - Build Ulang Web
echo    (hanya build, web server tidak dinyalakan)
echo ============================================
echo.

rem ---------- Validasi ----------
if not exist "%FLUTTER_BIN%\flutter.bat" (
    echo [ERROR] Flutter SDK tidak ditemukan di:
    echo         %FLUTTER_BIN%
    echo.
    pause
    exit /b 1
)

if not exist "%PROJECT%pubspec.yaml" (
    echo [ERROR] pubspec.yaml tidak ditemukan di:
    echo         %PROJECT%
    echo.
    pause
    exit /b 1
)

set "PATH=%FLUTTER_BIN%;%PATH%"
cd /d "%PROJECT%"

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "START=%%i"
echo Waktu mulai : %START%
echo Folder      : %PROJECT%
echo.

rem ---------- 1. Ambil dependency ----------
echo [1/3] flutter pub get ...
call flutter pub get
if errorlevel 1 (
    echo.
    echo [GAGAL] flutter pub get error. Build dibatalkan.
    pause
    exit /b 1
)
echo.

rem ---------- 2. Build web release ----------
echo [2/3] flutter build web --release ...
echo       (bisa 3-5 menit, jangan tutup jendela ini)
echo.
call flutter build web --release --base-href / --no-wasm-dry-run
if errorlevel 1 (
    echo.
    echo [GAGAL] Build web error. Periksa pesan di atas.
    pause
    exit /b 1
)

rem ---------- 3. Cek hasil ----------
if not exist "%PROJECT%build\web\index.html" (
    echo.
    echo [GAGAL] build\web\index.html tidak dihasilkan.
    pause
    exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "END=%%i"
for /f %%i in ('powershell -NoProfile -Command "$s=[math]::Round((Get-ChildItem '%PROJECT%build\web' -Recurse -File | Measure-Object Length -Sum).Sum/1MB,1); $s"') do set "SIZE=%%i"
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Item '%PROJECT%build\web\main.dart.js').LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss')"') do set "BUILT=%%i"

echo.
echo [3/3] Build selesai.
echo.
echo ============================================
echo    SELESAI (belum dinyalakan)
echo ============================================
echo   Mulai        : %START%
echo   Akhir        : %END%
echo   main.dart.js : %BUILT%
echo   Ukuran       : %SIZE% MB
echo   Folder hasil : %PROJECT%build\web
echo.
echo   Untuk menyalakan web: jalankan nyalakan_web.bat
echo ============================================
echo.
pause
exit /b 0
