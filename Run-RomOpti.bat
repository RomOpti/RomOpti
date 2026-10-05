@echo off
title Daqueece Optimizer
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0Rom-Opti.ps1\"' -Verb RunAs"
exit
