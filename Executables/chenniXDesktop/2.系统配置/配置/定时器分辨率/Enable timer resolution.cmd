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

if not "%~1"=="/silent" call "%windir%\chenniXModules\Scripts\serviceWarning.cmd" %*

reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" /v "GlobalTimerResolutionRequests" /t REG_DWORD /d "1" /f > nul
schtasks /create /tn "Force 定时器分辨率" /xml "%windir%\chenniXModules\Other\Force 定时器分辨率.xml" /f > nul
schtasks /run /tn "Force 定时器分辨率" > nul
if "%~1"=="/silent" exit /b

echo Finished, please reboot your device for changes to apply.
pause
exit /b