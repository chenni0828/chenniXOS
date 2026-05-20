@echo off
:: Change to match the setting name (e.g., 睡眠, Indexing, etc.)
set "settingName=蓝牙"
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

echo Disabling 蓝牙... This might take a minute.

:main
:: Disable 蓝牙 drivers and 服务
for %%a in (
	"蓝牙UserService"
	"BTAGService"
	"BthA2dp"
	"BthAvctpSvc"
	"BthEnum"
	"BthHFEnum"
	"BthLEEnum"
	"BthMini"
	"BTHMODEM"
	"BTHPORT"
	"bthserv"
	"BTHUSB"
	"HidBth"
	"Microsoft_蓝牙_AvrcpTransport"
	"RFCOMM"
) do (
	call "%windir%\chenniXModules\Scripts\setSvc.cmd" %%~a 4
)

:: Seems to not exist sometimes
call "%windir%\chenniXModules\Scripts\setSvc.cmd" BthPan 4 > nul 2>&1

:: Disable 蓝牙 devices
call "%windir%\chenniXModules\Scripts\toggleDev.cmd" -Silent '*蓝牙*'

:: Disable in 发送到 context menu
call "%windir%\chenniXDesktop\4.界面\右键菜单\发送到\Debloat 发送到 Context Menu.cmd" -Disable @('蓝牙')

:: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-connectivity
reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\Allow蓝牙" /v "value" /t REG_DWORD /d "0" /f > nul

if "%~1" == "/silent" exit

echo Finished, please reboot your device for changes to apply.
pause
exit /b
