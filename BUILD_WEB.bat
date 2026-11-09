@echo off
setlocal
cd /d "%~dp0"
title FitMe - web build

call flutter pub get
if errorlevel 1 goto failed
call flutter build web --release --base-href /app/
if errorlevel 1 goto failed

rem The backend serves this folder at /app/ (robocopy: 0-7 mean success).
robocopy build\web backend\app\web_app /MIR /NFL /NDL /NJH /NJS /NP
if errorlevel 8 goto failed

echo.
echo Web version is ready. Start the server and open /app/ on its address.
pause
exit /b 0

:failed
echo.
echo ERROR: the web build failed, see the messages above.
pause
exit /b 1
