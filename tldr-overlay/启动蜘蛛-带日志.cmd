@echo off
rem Same app, but with a console window that shows the log while it runs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TldrOverlay.ps1" -Console
