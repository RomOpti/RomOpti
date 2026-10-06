@echo off
setlocal
title Rom-Opti
set "RO_PS1=%~dp0Rom-Opti.ps1"
if not exist "%RO_PS1%" (
  echo Rom-Opti.ps1 was not found next to this file:
  echo   %RO_PS1%
  pause
  exit /b 1
)
net session >nul 2>&1
if %errorlevel%==0 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RO_PS1%"
  if errorlevel 1 pause
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([char]34+$env:RO_PS1+[char]34) } catch { Write-Host 'Administrator permission was declined, so Rom-Opti did not start.'; exit 1 }"
if errorlevel 1 pause
