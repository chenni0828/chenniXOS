@echo off
set "settingName=Indexing"
set "stateValue=0"
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

reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

echo.
echo Disabling 搜索索引...
%indexConf% /stop

echo.
echo 搜索索引 has been disabled.
echo Press any key to exit...
pause > nul
exit /b
