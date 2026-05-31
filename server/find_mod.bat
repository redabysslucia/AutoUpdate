@echo off
chcp 65001 >nul
cd /d "%~dp0"

if "%~1"=="" (
    echo.
    echo Usage:
    echo   find_mod ^<keyword^>          - Search CurseForge/Modrinth for a mod
    echo   find_mod ^<keyword^> --auto    - Search AND auto-fill from jar file
    echo.
    echo Examples:
    echo   find_mod create
    echo   find_mod "touhou little maid"
    echo   find_mod sodium --auto files\mods\dd004f7a_sodium.jar
    echo.
    echo   For auto-matching ALL unmapped mods, use: find_sources.bat
    echo.
    pause
    exit /b
)

echo ========================================
echo   Search: %~1
echo ========================================
echo.

if "%~2"=="--auto" (
    echo Auto-match mode: %~3
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find_mod_source.ps1" -ModFile "%~3"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find_mod_source.ps1" -ModName "%~1"
)

pause
