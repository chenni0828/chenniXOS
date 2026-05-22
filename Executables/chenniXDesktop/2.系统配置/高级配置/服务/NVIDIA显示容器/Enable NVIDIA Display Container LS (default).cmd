@echo off
:: Change to match the setting name (e.g., 睡眠, Indexing, etc.)
set "settingName=NVidiaDisplayContainer"
:: Change to 0 (Disabled) or 1 (Enabled/Minimal) etc
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

:: Update Registry (State and Path)
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v state /t REG_DWORD /d %stateValue% /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\服务\%settingName%" /v path /t REG_SZ /d "%scriptPath%" /f > nul

if not "%~1"=="/silent" call "%windir%\chenniXModules\Scripts\serviceWarning.cmd" %*

:main
:: check if the service exists
reg query "HKLM\SYSTEM\CurrentControlSet\服务\NVDisplay.ContainerLocalSystem" > nul 2>&1 || (
	if "%~1"=="/silent" exit /b
    echo The NVIDIA显示容器 LS service does not exist, you cannot continue.
	echo You may not have NVIDIA drivers installed.
    echo]
    pause
    exit /b
)

call "%windir%\chenniXModules\Scripts\setSvc.cmd" NVDisplay.ContainerLocalSystem 2
sc start NVDisplay.ContainerLocalSystem > nul 2>&1

if "%~1"=="/silent" exit /b

echo Finished, changes have been applied.
pause
exit /b