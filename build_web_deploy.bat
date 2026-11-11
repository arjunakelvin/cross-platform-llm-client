@echo off
setlocal EnableExtensions
title PiercingBlow - Build Web + siap deploy ke Vercel

rem ============================================================
rem  1. flutter build web --release
rem  2. salin isi folder web\ (admin, api, vercel.json, dll)
rem     ke build\web\  <- ini yang di-deploy ke Vercel
rem  3. cek cepat: /admin/ dan /api/admin/health
rem ============================================================

set "PROJECT=%~dp0"
set "FLUTTER_BIN=C:\flutter\flutter\bin"

if not exist "%FLUTTER_BIN%\flutter.bat" (
    echo [ERROR] Flutter tidak ditemukan di %FLUTTER_BIN%
    echo         ganti FLUTTER_BIN di script ini kalau Flutter di tempat lain.
    pause
    exit /b 1
)

cd /d "%PROJECT%"

echo.
echo [1/3] flutter pub get ...
call "%FLUTTER_BIN%\flutter.bat" pub get || goto :gagal

echo.
echo [2/3] flutter build web --release ...
call "%FLUTTER_BIN%\flutter.bat" build web --release --base-href / || goto :gagal

echo.
echo [3/3] menyalin file web\ ke build\web\ ...
if not exist "build\web" (
    echo [ERROR] build\web tidak ada — build gagal?
    pause
    exit /b 1
)
xcopy "web\admin" "build\web\admin\" /E /I /Y /Q >nul
xcopy "web\api" "build\web\api\" /E /I /Y /Q >nul
xcopy "web\icons" "build\web\icons\" /E /I /Y /Q >nul
copy /Y "web\vercel.json" "build\web\vercel.json" >nul
copy /Y "web\ios-gen.html" "build\web\ios-gen.html" >nul
copy /Y "web\test_image_gen.html" "build\web\test_image_gen.html" >nul
copy /Y "web\webgpu_engine.js" "build\web\webgpu_engine.js" >nul
echo       selesai.

echo.
echo ============================================
echo    SIAP DEPLOY
echo    Folder yang di-deploy: build\web
echo.
echo    Vercel  : import folder build\web, atau
echo              npx vercel deploy build\web --prod
echo    Worker  : cd proxy
echo              npx wrangler secret put ADMIN_KEY
echo              npx wrangler deploy
echo    (route piercingblow.ai.id/api* sudah di wrangler.toml)
echo.
echo    Cek setelah deploy:
echo      curl -i https://piercingblow.ai.id/api/admin/health ^
echo           -H "X-Admin-Key: <ADMIN_KEY>"
echo ============================================
echo.
pause
exit /b 0

:gagal
echo.
echo [GAGAL] Build web error. Lihat pesan di atas.
pause
exit /b 1
