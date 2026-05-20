.\chenniXModules\initPowerShell.ps1
$windir = [Environment]::GetFolderPath('Windows')

Write-Title "Creating Desktop & 开始菜单 shortcuts..."

# Default user
$defaultShortcut = "$(Get-UserPath)\chenniX.lnk"
New-Shortcut -Source "$windir\chenniXDesktop" -Destination $defaultShortcut -Icon "$windir\chenniXModules\Other\chenniX-folder.ico,0"

# Copy shortcut to every user
foreach ($userKey in (Get-RegUserPaths -NoDefault).PsPath) {
	$folders = Get-ItemProperty -path "$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
	$deskPath = $folders.Desktop
	if (Test-Path $deskPath -PathType Container) {
		Write-Output "Copying Desktop shortcut for '$userKey'..."
		Copy-Item $defaultShortcut -Destination $deskPath -Force
	} else {
		Write-Error "Desktop path not found for '$userKey', shortcuts can't be copied."
	}
}

# Start menu shortcut
Copy-Item $defaultShortcut -Destination "$([Environment]::GetFolderPath('CommonStartMenu'))\Programs" -Force

Write-Title "Creating services restore shortcut..."
$desktop = "$windir\chenniXDesktop"
New-Shortcut -Source "$desktop\3.安全与修复\故障排除\Set services to defaults.cmd" -Destination "$desktop\2.系统配置\高级配置\服务\Set services to defaults.lnk"