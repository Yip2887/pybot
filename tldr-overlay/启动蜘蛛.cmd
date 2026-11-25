@echo off
rem TL;DR Overlay - double-click this. No console window, no install.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TldrOverlay.ps1"
