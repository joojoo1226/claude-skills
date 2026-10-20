@echo off
rem Nextcloud Drive - one-time credential registration.
rem Double-click this file, then type your username and app password.
setlocal
chcp 65001 >nul
title Nextcloud Drive - login
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\nxdrive.ps1" -Action login
echo.
echo Press any key to close this window...
pause >nul
