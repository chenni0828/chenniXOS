@echo off
set "settingName=UselessDevices"
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

reg add "HKLM\SOFTWARE\chenniXOS\Services\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\Services\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

echo Disabling devices...
pnputil /disable-device "ROOT\CompositeBus\0000"
pnputil /disable-device "ROOT\vdrvroot\0000"
pnputil /disable-device "ROOT\UMBUS\0000"
pnputil /disable-device "ROOT\NdisVirtualBus\0000"

if "%~1" == "/silent" exit

echo.
echo Done. Reboot for changes to take effect.
pause
exit /b
