@echo off

set "restore_delay=1000"
set "restore_accept=1000"

for /f "tokens=3" %%v in ('reg query "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay_Backup" 2^>nul ^| findstr "AutoRepeatDelay_Backup"') do set "restore_delay=%%v"
for /f "tokens=3" %%v in ('reg query "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance_Backup" 2^>nul ^| findstr "DelayBeforeAcceptance_Backup"') do set "restore_accept=%%v"

reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay" /t REG_SZ /d "%restore_delay%" /f > nul
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance" /t REG_SZ /d "%restore_accept%" /f > nul

reg delete "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay_Backup" /f > nul 2>&1
reg delete "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance_Backup" /f > nul 2>&1

if "%~1"=="/silent" exit /b

echo 键盘轮询率已恢复为系统默认值。
pause
exit /b