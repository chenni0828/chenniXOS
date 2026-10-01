@echo off
:: Adapted from Atlas-main: Disable Recall Support (default).cmd

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


reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /t REG_DWORD /d 1 /f > nul
if errorlevel 1 exit /b 1
if "%~1"=="/silent" exit /b 0

echo.
echo Recall has been disabled.
echo Press any key to exit...
pause > nul
exit /b
