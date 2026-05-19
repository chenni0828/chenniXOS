if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { 
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit 
}

$windir = [Environment]::GetFolderPath('Windows')
& "$windir\chenniXModules\initPowerShell.ps1"
$chenniXDesktop = "$windir\chenniXDesktop"
$chenniXModules = "$windir\chenniXModules"

$title = 'Preparing chenniX user settings...'

if (!(Test-Path $chenniXDesktop) -or !(Test-Path $chenniXModules)) {
    Write-Host "chenniX was about to configure user settings, but its files weren't found. :(" -ForegroundColor Red
    Read-Pause
    exit 1
}

$Host.UI.RawUI.WindowTitle = $title
Write-Host $title -ForegroundColor Yellow
Write-Host $('-' * ($title.length + 3)) -ForegroundColor Yellow
Write-Host "You'll be logged out in 10 to 20 seconds, and once you login again, your new account will be ready for use."

# Disable Windows 11 context menu & 'Gallery' in File Explorer
if ([System.Environment]::OSVersion.Version.Build -ge 22000) {
    & "$chenniXDesktop\1.系统配置\界面\右键菜单\Windows 11\Old Context Menu (default).cmd" /silent
    & "$chenniXDesktop\1.系统配置\界面\文件资源管理器\图库\Disable Gallery (default).cmd" /silent

    # Set ThemeMRU (recent themes)
    Set-Theme -Path "$([Environment]::GetFolderPath('Windows'))\Resources\Themes\chenniX-dark.theme"
    Set-ThemeMRU | Out-Null
}

# Set lockscreen wallpaper
Set-LockscreenImage

# Disable 'Network' in navigation pane
& "$chenniXDesktop\1.系统配置\配置\文件共享\网络导航窗格\Disable Network Navigation Pane (default).cmd" /silent

# Disable 自动文件夹发现
& "$chenniXDesktop\1.系统配置\界面\文件资源管理器\自动文件夹发现\Disable Automatic Folder Discovery (default).cmd" /silent

# Apply visual effects
& "$chenniXDesktop\1.系统配置\界面\视觉效果(动画)\Atlas Visual Effects (default).cmd" /silent

# Set taskbar pins 
$valueName = "Browser"
$value = Get-ItemProperty -Path "HKLM:\SOFTWARE\chenniXOS\SetupOptions" -Name $valueName -ErrorAction Stop
$Browser = $value.$valueName
$Browser

& "$chenniXModules\Scripts\taskbarPins.ps1" $Browser
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value 1

# Leave
Start-Sleep 5 
logoff
