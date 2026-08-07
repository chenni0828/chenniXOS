@echo off
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

:main
setlocal EnableDelayedExpansion

:: 状态记录（为日后 chenniXOS Toolkit 预留：state=0=禁用 / 1=启用）
reg add "HKLM\SOFTWARE\chenniXOS\Services\Indexing" /v state /t REG_DWORD /d 0 /f > nul
reg add "HKLM\SOFTWARE\chenniXOS\Services\Indexing" /v path /t REG_SZ /d "%~f0" /f > nul

echo.
echo Disabling Windows Search indexing...

:: 禁用并停止 Windows Search 服务（WSearch）
sc config WSearch start=disabled > nul
sc stop WSearch > nul 2>&1

if "%~1"=="/silent" exit /b

echo.
echo Search Indexing has been disabled.
echo Finished, please reboot your device for changes to apply.
pause
exit /b
