@echo off
title GPU Rename Tool
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu-rename.ps1"
echo.
pause