@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ========================================
echo   Modpack Update Generator
echo ========================================
echo.

set BUMP=%~1
if "%BUMP%"=="" set BUMP=patch

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_update.ps1" -VersionBump "%BUMP%"

echo.
echo ========================================
echo   Done! Check modpack.json for result.
echo ========================================
pause
