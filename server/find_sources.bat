@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ========================================
echo   Auto-Match Mod Sources
echo   Scan jars ^>^> match on Modrinth ^>^> auto-fill
echo ========================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find_mod_source.ps1"

pause
