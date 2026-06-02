@echo off
title Rom Opti Launcher
echo Launching Rom Opti (requesting administrator rights)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Rom-Opti.ps1\"' -Verb RunAs"
exit
