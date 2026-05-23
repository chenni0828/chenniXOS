@echo off
set "settingName=Indexing"
set "stateValue=1"
set "scriptPath=%~f0"
set indexConfPath="%windir%\chenniXModules\Scripts\indexConf.cmd"

whoami /user | find /i "S-1-5-18" > nul 2>&1 || (
    call RunAsTI.cmd "%~f0" %*
    exit /b
)

if not exist "%indexConfPath%" (
    echo The 'indexConf.cmd' script wasn't found in chenniXModules.
    pause
    exit /b 1
)
set "indexConf=call %indexConfPath%"

reg add "HKLM\SOFTWARE\chenniXOS\Services\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\Services\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

echo.
echo Configuring minimal 搜索索引...
%indexConf% /stop
%indexConf% /cleanpolicies
%indexConf% /include "%programdata%\Microsoft\Windows\开始菜单\Programs"
%indexConf% /include "%windir%\chenniXDesktop"
%indexConf% /exclude "%systemdrive%\Users"

reg add "HKLM\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex" /v "RespectPowerModes" /t REG_DWORD /d 1 /f > nul

%indexConf% /start
reg add "HKLM\SOFTWARE\Microsoft\Windows Search" /v SetupCompletedSuccessfully /t REG_DWORD /d 0 /f > nul

if "%~1"=="/silent" exit /b

echo.
echo Minimal 搜索索引 has been configured.
echo Press any key to exit...
pause
exit /b
