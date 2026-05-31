@echo off
chcp 65001 >nul
cd /d "%~dp0"

set BUMP=%~1
if "%BUMP%"=="" set BUMP=patch

echo ========================================
echo   Modpack Update Generator v3.0
echo ========================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_update.ps1" -VersionBump "%BUMP%"

echo.
echo ========================================
echo   Done!
echo   Next: git add . ^&^& git commit -m "v^<new^>" ^&^& git push
echo ========================================
pause
