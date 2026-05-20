@echo off
set "settingName=位置"
set "stateValue=1"
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
    sc config lfsvc start=demand
    sc config MapsBroker start=auto
) > nul

(
    sc start lfsvc
    sc start MapsBroker
) > nul 2>&1

call "%windir%\chenniXModules\Scripts\settingsPages.cmd" /unhide privacy-位置

set key1="HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice"
choice /c:yn /n /m "Would you like to unlock Find My Device functionality? [Y/N] "
if %errorlevel%==1 (
    reg delete %key1% /f > nul
    call "%windir%\chenniXModules\Scripts\settingsPages.cmd" /unhide findmydevice /silent
)
if %errorlevel%==2 (
    reg add %key1% /v AllowFindMyDevice /t REG_DWORD /d 0 /f > nul
    reg add %key1% /v 位置SyncEnabled /t REG_DWORD /d 0 /f > nul
)

if "%~1"=="/silent" exit /b

echo.
echo 位置 服务 have been enabled.
start ms-settings:privacy-位置
echo Press any key to exit...
pause
exit /b
