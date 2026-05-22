@echo off
:: Change to match the setting name (e.g., 睡眠, Indexing, etc.)
set "settingName=网络Discovery"
:: Change to 0 (Disabled) or 1 (Enabled/Minimal) etc
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

:: Update Registry (State and Path)
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

if not "%~1"=="/silent" call "%windir%\chenniXModules\Scripts\serviceWarning.cmd" %*

:: Unpin '网络' from Explorer sidebar
call "%windir%\chenniXDesktop\3.配置\文件共享\网络 Navigation Pane\Disable 网络 Navigation Pane (default).cmd" > nul

call "%windir%\chenniXModules\Scripts\setSvc.cmd" fdPHost 4
call "%windir%\chenniXModules\Scripts\setSvc.cmd" FDResPub 4
call "%windir%\chenniXModules\Scripts\setSvc.cmd" lmhosts 4
call "%windir%\chenniXModules\Scripts\setSvc.cmd" SSDPSRV 4
if "%~1"=="/silent" exit /b

echo Finished, please reboot your device for changes to apply.
pause
exit /b
