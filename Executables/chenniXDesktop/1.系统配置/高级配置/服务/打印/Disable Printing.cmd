@echo off
:: Change to match the setting name (e.g., 睡眠, Indexing, etc.)
set "settingName=打印"
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

if /i not "%~1"=="/silent" if /i not "%~1"=="/justcontext" call "%windir%\chenniXModules\Scripts\serviceWarning.cmd" %*

setlocal EnableDelayedExpansion

if "%~1" == "/silent" goto main
if "%~1" == "/justcontext" goto main

:main
echo Disabling 打印...
echo]

echo Removing 'Print' from context menu...
reg add "HKCR\SystemFileAssociations\image\shell\print" /v "ProgrammaticAccessOnly" /t REG_SZ /d "" /f > nul
for %%a in (
    "batfile"
    "cmdfile"
    "docxfile"
    "fonfile"
    "htmlfile"
    "inffile"
    "inifile"
    "JSEFile"
    "otffile"
    "pfmfile"
    "regfile"
    "rtffile"
    "ttcfile"
    "ttffile"
    "txtfile"
    "VBEFile"
    "VBSFile"
    "WSFFile"
) do (
    reg add "HKCR\%%~a\shell\print" /v "ProgrammaticAccessOnly" /t REG_SZ /d "" /f > nul
)
for /f "tokens=6 delims=[.] " %%a in ('ver') do (
    if %%a GEQ 22000 (
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\Print" /v "LegacyDisable" /t REG_SZ /d "" /f > nul
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\Print" /v "ProgrammaticAccessOnly" /t REG_SZ /d "" /f > nul
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\Print" /v "HideBasedOnVelocityId" /t REG_DWORD /d "6527944" /f > nul
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\PrintTo" /v "LegacyDisable" /t REG_SZ /d "" /f > nul
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\PrintTo" /v "ProgrammaticAccessOnly" /t REG_SZ /d "" /f > nul
        reg add "HKCR\AppX4ztfk9wxr86nxmzzq47px0nh0e58b8fw\Shell\PrintTo" /v "HideBasedOnVelocityId" /t REG_DWORD /d "6527944" /f > nul
    )
)

if "%~1" == "/justcontext" exit /b

echo Disabling 服务...
call "%windir%\chenniXModules\Scripts\setSvc.cmd" Spooler 4
call "%windir%\chenniXModules\Scripts\setSvc.cmd" PrintWorkFlowUserSvc 4

call "%windir%\chenniXModules\Scripts\settingsPages.cmd" /hide printers

echo Disabling features...
for %%a in (
    "打印-Foundation-Features"
    "打印-Foundation-Internet打印-Client"
    "打印-XPS服务-Features"
    "打印-PrintToPDF服务-Features"
) do (
    dism /Online /Disable-Feature /FeatureName:"%%a" /NoRestart > nul
)

if "%~1" == "/silent" exit /b

echo]
echo Finished, please reboot your device for changes to apply.
pause
exit /b