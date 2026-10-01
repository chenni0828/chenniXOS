<#
  chenniXOS CLEANUP.ps1 - 安装后清理
  改写自 AtlasPlaybook CLEANUP.ps1 (Atlas-OS, MIT)。
  移除了 AtlasModules\initPowerShell.ps1 的 dot-source；Get-SystemDrive 已内联。
#>

$ErrorActionPreference = 'Continue'

# 内联自 AtlasModules（返回系统盘，如 'C:'）
function Get-SystemDrive { $env:SystemDrive }

function Invoke-chenniXDiskCleanup {
    # 终止正在运行的 cleanmgr 实例，否则会阻止新的 cleanmgr 启动
    Get-Process -Name cleanmgr -EA 0 | Stop-Process -Force -EA 0
    # 磁盘清理预设
    # 2 = 启用
    # 0 = 禁用
    $baseKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $regValues = @{
        "Active Setup Temp Folders"             = 2
        "BranchCache"                           = 2
        "D3D Shader Cache"                      = 0
        "Delivery Optimization Files"           = 2
        "Diagnostic Data Viewer database files" = 2
        "Downloaded Program Files"              = 2
        "Internet Cache Files"                  = 2
        "Language Pack"                         = 0
        "Old ChkDsk Files"                      = 2
        "Recycle Bin"                           = 0
        "RetailDemo Offline Content"            = 2
        "Setup Log Files"                       = 2
        "System error memory dump files"        = 2
        "System error minidump files"           = 2
        "Temporary Files"                       = 0
        "Thumbnail Cache"                       = 2
        "Update Cleanup"                        = 0
        "User file versions"                    = 2
        "Windows Error Reporting Files"         = 2
        "Windows Defender"                      = 2
        "Temporary Sync Files"                  = 2
        "Device Driver Packages"                = 2
    }
    foreach ($entry in $regValues.GetEnumerator()) {
        $key = "$baseKey\$($entry.Key)"
        if (!(Test-Path $key)) {
            Write-Output "'$key' not found, not configuring it."
        }
        else {
            Set-ItemProperty -Path "$baseKey\$($entry.Key)" -Name 'StateFlags0064' -Value $entry.Value -Type DWORD
        }
    }
    # 运行预设 64（0-65535）
    # 由于 cleanmgr 会启动多个进程，隐藏窗口没有意义（不会生效）
    Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:64" 2>&1 | Out-Null
}
# 检查是否存在其他 Windows 安装
# 若存在则不清理，因为会同时清理其他盘（很慢），且不应触碰其他数据
$noCleanmgr = $false
$drives = (Get-PSDrive -PSProvider FileSystem).Root | Where-Object { $_ -notmatch $(Get-SystemDrive) }
foreach ($drive in $drives) {
    if (Test-Path -Path $(Join-Path -Path $drive -ChildPath 'Windows') -PathType Container) {
        Write-Output "Not running Disk Cleanup, other Windows drives found."
        $noCleanmgr = $true
        break
    }
}
if (!$noCleanmgr) {
    Write-Output "No other Windows drives found, running Disk Cleanup."
    Invoke-chenniXDiskCleanup
}
# 清理用户 temp 文件夹
foreach ($path in @($env:temp, $env:tmp, "$env:localappdata\Temp")) {
    if (Test-Path $path -PathType Container) {
        $userTemp = $path
        break
    }
}
if ($userTemp) {
    Write-Output "Cleaning user TEMP folder..."
    Get-ChildItem -Path $userTemp | Where-Object { $_.Name -ne 'AME' } | Remove-Item -Force -Recurse -EA 0
}
else {
    Write-Error "User temp folder not found!"
}
# 清理系统 temp 文件夹
$machine = [System.EnvironmentVariableTarget]::Machine
foreach ($path in @(
        [System.Environment]::GetEnvironmentVariable("Temp", $machine),
        [System.Environment]::GetEnvironmentVariable("Tmp", $machine),
        "$([Environment]::GetFolderPath('Windows'))\Temp"
    )) {
    if (Test-Path $path -PathType Container) {
        $sysTemp = $path
        break
    }
}
if ($sysTemp) {
    Write-Output "Cleaning system TEMP folder..."
    Remove-Item -Path "$sysTemp\*" -Force -Recurse -EA 0
}
else {
    Write-Error "System temp folder not found!"
}
# 删除所有系统还原点
# 防止用户试图用还原点从 chenniXOS 回退到原版系统
# 这行不通，必须完全重装 Windows ^
vssadmin delete shadows /all /quiet
