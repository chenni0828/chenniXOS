@echo off
set "settingName=睡眠Study"
set "stateValue=0"
set "scriptPath=%~f0"

set "___args="%~f0" %*"
fltmc > nul 2>&1 || (
    echo Administrator privileges are required.
    powershell -c "Start-Process -Verb RunAs -FilePath 'cmd' -ArgumentList """/c $env:___args"""" 2> nul || (
        echo You must run this script as admin.
        if "%*"=="" pause
        exit /b 1
    )
    exit /b
)

reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

for %%a in (
    "Microsoft-Windows-睡眠Study/Diagnostic"
    "Microsoft-Windows-Kernel-Processor-Power/Diagnostic"
    "Microsoft-Windows-UserModePowerService/Diagnostic"
) do (
    wevtutil sl "%%~a" /q:false > nul
)

schtasks /change /tn "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem" /disable > nul
if "%~1"=="/silent" exit /b

echo.
echo 睡眠研究 has been disabled.
echo Press any key to exit...
pause > nul
exit /b
