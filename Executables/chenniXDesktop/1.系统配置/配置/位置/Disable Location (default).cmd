@echo off
set "settingName=位置"
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

if not "%~1"=="/silent" call "%windir%\chenniXModules\Scripts\serviceWarning.cmd" %*

(
    sc config lfsvc start=disabled
    sc config MapsBroker start=disabled
    reg add "HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice" /v AllowFindMyDevice /t REG_DWORD /d 0 /f
    reg add "HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice" /v 位置SyncEnabled /t REG_DWORD /d 0 /f
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\位置" /v "ShowGlobalPrompts" /t REG_DWORD /d 0 /f
) > nul

(
    sc stop lfsvc
    sc stop MapsBroker
) > nul 2>&1

for %%a in (
    "privacy-位置"
    "findmydevice"
) do (
    call "%windir%\chenniXModules\Scripts\settingsPages.cmd" /hide %%~a /silent
)

if "%~1"=="/silent" exit /b

echo.
echo 位置 服务 have been disabled.
echo Press any key to exit...
pause
exit /b