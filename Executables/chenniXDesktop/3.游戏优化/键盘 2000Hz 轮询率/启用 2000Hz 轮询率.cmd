@echo off

set "current_delay=1000"
set "current_accept=1000"

for /f "tokens=3" %%v in ('reg query "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay" 2^>nul ^| findstr "AutoRepeatDelay"') do set "current_delay=%%v"
for /f "tokens=3" %%v in ('reg query "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance" 2^>nul ^| findstr "DelayBeforeAcceptance"') do set "current_accept=%%v"

if not "%current_delay%"=="2000" (
    reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay_Backup" /t REG_SZ /d "%current_delay%" /f > nul
)
if not "%current_accept%"=="2000" (
    reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance_Backup" /t REG_SZ /d "%current_accept%" /f > nul
)

reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "AutoRepeatDelay" /t REG_SZ /d "2000" /f > nul
reg add "HKCU\Control Panel\Accessibility\Keyboard Response" /v "DelayBeforeAcceptance" /t REG_SZ /d "2000" /f > nul

if "%~1"=="/silent" exit /b

echo 键盘轮询率已设置为 2000Hz。
echo 注意：仅部分键盘（如 K5V2）支持此功能。
pause
exit /b