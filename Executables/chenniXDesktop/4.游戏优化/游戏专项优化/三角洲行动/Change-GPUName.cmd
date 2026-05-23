@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Start-Process %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ArgumentList '-ExecutionPolicy Bypass -NoProfile -File \"%~dp0Change-GPUName.ps1\"' -Verb RunAs"
    exit /b
)
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Change-GPUName.ps1"
