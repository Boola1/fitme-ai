@echo off
setlocal
cd /d "%~dp0"
echo ================================================================
echo FitMe AI - build APK for phone (works without PC)
echo ================================================================
echo Paste backend URL, e.g. https://yourname-fitme-backend.hf.space
set /p "API_URL=Backend URL: "
if not defined API_URL (
  echo ERROR: URL is empty.
  pause
  exit /b 1
)
if "%API_URL:~-1%"=="/" set "API_URL=%API_URL:~0,-1%"
call flutter pub get
call flutter build apk --release --dart-define=API_BASE_URL=%API_URL%
if errorlevel 1 (
  echo.
  echo ERROR: build failed, see messages above.
  pause
  exit /b 1
)
if not exist web\downloads mkdir web\downloads
copy /y build\app\outputs\flutter-apk\app-release.apk web\downloads\FitMe.apk >nul
echo.
echo APK: %~dp0build\app\outputs\flutter-apk\app-release.apk
echo Also copied to web\downloads\FitMe.apk: the site offers it after the next site build.
explorer "%~dp0build\app\outputs\flutter-apk"
pause
endlocal
