@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FitMe - local GPU + wireless
set "LOG=%~dp0start_log.txt"
echo FitMe start %DATE% %TIME% > "%LOG%"
set "GPY=%~dp0gpu_server\.venv\Scripts\python.exe"

if not exist "%GPY%" (
  echo ERROR: run INSTALL_LOCAL_GPU.bat first. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
if not exist "backend\.venv\Scripts\python.exe" (
  echo ERROR: run INSTALL_LOCAL_GPU.bat first. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)

rem ---- access key shared by backend and phone app (discovery.json, never committed) ----
for /f "usebackq delims=" %%K in (`"%GPY%" gpu_server\discovery_value.py key`) do set "FITME_API_KEY=%%K"
if not defined FITME_API_KEY (
  echo ERROR: could not create discovery.json >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)

rem ---- cloudflared for internet access (same tool as in the Kaggle notebook) ----
if not exist "tools\cloudflared.exe" (
  echo Downloading cloudflared...
  if not exist tools mkdir tools
  powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile 'tools\cloudflared.exe'" >> "%LOG%" 2>&1
)

echo Stopping old FitMe processes...
rem closes old GPU/backend/tunnel windows (an old tunnel would keep announcing a second address)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu_server\close_extra_windows.ps1" -StopAll >> "%LOG%" 2>&1
for %%Q in (7860 8000) do (
  for /f "tokens=5" %%P in ('netstat -aon ^| findstr ":%%Q " ^| findstr "LISTENING"') do taskkill /PID %%P /F >nul 2>&1
)
taskkill /IM cloudflared.exe /F >nul 2>&1

echo [1/3] FASHN on your GPU (first start loads the model, up to 2-3 min)...
start "FitMe GPU (FASHN)" /D "%~dp0gpu_server" cmd /k .venv\Scripts\python.exe fashn_server.py
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 120;$i++){ try { $r=Invoke-RestMethod 'http://127.0.0.1:7860/health' -TimeoutSec 3; if($r.status -eq 'ready'){ $ok=$true; break } } catch {}; Start-Sleep -Seconds 3 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: GPU server did not start - see the "FitMe GPU (FASHN)" window. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
echo GPU server ready >> "%LOG%"

echo [2/3] Backend...
rem new libraries of v4 (database stats, re-colouring); quick when already installed
backend\.venv\Scripts\python.exe -m pip install -q -r backend\requirements.txt >> "%LOG%" 2>&1
set "FITME_REMOTE_AI_URL=http://127.0.0.1:7860"
set "FITME_AI_PROVIDER=kaggle"
set "FITME_FASHN_STEPS=20"
start "FitMe Backend" /D "%~dp0backend" cmd /k .venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 40;$i++){ try { $r=Invoke-RestMethod 'http://127.0.0.1:8000/health' -TimeoutSec 5; if($r.status -eq 'online'){ $ok=$true; break } } catch {}; Start-Sleep -Seconds 1 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: backend did not start - see the "FitMe Backend" window. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
echo Backend ready >> "%LOG%"

echo [3/3] Wireless: Wi-Fi + internet tunnel...
if exist tunnel_status.txt del tunnel_status.txt
start "FitMe Wireless (tunnel)" /D "%~dp0" cmd /k gpu_server\.venv\Scripts\python.exe gpu_server\tunnel.py
for /l %%i in (1,1,45) do (
  if not exist tunnel_status.txt timeout /t 2 >nul
)

rem ---- USB is optional now, but keep it working when the cable is plugged in ----
set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if exist "%ADB%" "%ADB%" reverse tcp:8000 tcp:8000 >nul 2>&1

if exist tunnel_status.txt type tunnel_status.txt >> "%LOG%"
type "%LOG%"
echo.
echo ================================================================
echo  FitMe is running. Phone works by Wi-Fi or mobile internet -
echo  keep the laptop ON, plugged in and online. Do not close the 3 FitMe windows.
if exist "backend\app\web_app\index.html" (
  echo.
  echo  Web version: http://127.0.0.1:8000/app/?key=%FITME_API_KEY%
  echo  From another device use the Wi-Fi or tunnel address instead of 127.0.0.1.
)
echo ================================================================
pause
endlocal
