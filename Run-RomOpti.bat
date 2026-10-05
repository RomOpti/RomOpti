@echo off
setlocal

title Rom-Opti Enhanced

REM ============================================================
REM Rom-Opti Enhanced Launcher
REM ============================================================

set "SCRIPT=%~dp0Rom-Opti-Enhanced.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo [ERROR] Rom-Opti-Enhanced.ps1 was not found.
    echo.
    echo This BAT must be in the same folder as:
    echo Rom-Opti-Enhanced.ps1
    echo.
    pause
    exit /b 1
)

REM Check for Administrator privileges
net session >nul 2>&1

if %errorlevel% neq 0 (
    echo.
    echo Requesting Administrator privileges...
    echo.

    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -Command "Start-Process -FilePath '%~f0' -Verb RunAs"

    exit /b
)

echo.
echo ============================================================
echo                    ROM-OPTI ENHANCED
echo ============================================================
echo.
echo Script:
echo %SCRIPT%
echo.
echo Starting...
echo.

powershell.exe ^
    -NoLogo ^
    -NoProfile ^
    -ExecutionPolicy Bypass ^
    -File "%SCRIPT%"

set "EXITCODE=%errorlevel%"

echo.
echo ============================================================
echo Rom-Opti exited with code %EXITCODE%
echo ============================================================
echo.

pause
exit /b %EXITCODE%
