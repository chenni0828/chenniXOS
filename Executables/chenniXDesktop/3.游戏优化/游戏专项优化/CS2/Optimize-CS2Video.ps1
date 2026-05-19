$ErrorActionPreference = "Stop"
$scriptDir = "$PSScriptRoot"
$backupFile = "$scriptDir\CS2VideoBackup.txt"

$steamPath = $null
$regPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
    "HKLM:\SOFTWARE\Valve\Steam",
    "HKCU:\SOFTWARE\Valve\Steam"
)

foreach ($reg in $regPaths) {
    $prop = Get-ItemProperty -Path $reg -Name "InstallPath" -EA 0
    if ($prop -and $prop.InstallPath) {
        $steamPath = $prop.InstallPath
        break
    }
}

if (-not $steamPath) {
    $defaultPath = "C:\Program Files (x86)\Steam"
    if (Test-Path $defaultPath) {
        $steamPath = $defaultPath
    }
}

if (-not $steamPath) {
    Write-Host "未找到 Steam 安装路径。" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "Steam 安装路径: $steamPath" -ForegroundColor Cyan

$configFiles = @()
$userdataPath = Join-Path $steamPath "userdata"
if (Test-Path $userdataPath) {
    $configFiles = @(Get-ChildItem -Path $userdataPath -Recurse -Filter "cs2_video.txt" -EA 0 |
        Where-Object { $_.FullName -like "*\730\local\cfg\cs2_video.txt" })
}

if ($configFiles.Count -eq 0) {
    Write-Host "未找到 CS2 视频配置文件。" -ForegroundColor Red
    Write-Host "请确保已安装 CS2 并至少启动过一次。" -ForegroundColor Yellow
    pause
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   CS2 视频配置优化工具" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "找到以下 CS2 视频配置文件：" -ForegroundColor Yellow
foreach ($f in $configFiles) {
    $userId = $f.Directory.Parent.Parent.Name
    Write-Host "  用户 $userId : $($f.FullName)" -ForegroundColor White
}

Write-Host ""
Write-Host "将修改以下设置：" -ForegroundColor Yellow
Write-Host "  setting.gpu_mem_level  → 0 (显存等级)" -ForegroundColor White
Write-Host "  setting.gpu_level      → 0 (GPU等级)" -ForegroundColor White
Write-Host ""

$confirm = Read-Host "确认修改？(y/N)"
if ($confirm -notmatch '^[yY]') {
    Write-Host "已取消。" -ForegroundColor Yellow
    pause
    exit 0
}

$backupData = @()
foreach ($f in $configFiles) {
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))
    $userId = $f.Directory.Parent.Parent.Name

    $gpuMemMatch = [regex]::Match($content, '"setting\.gpu_mem_level"\s+"(\d+)"')
    $gpuLevelMatch = [regex]::Match($content, '"setting\.gpu_level"\s+"(\d+)"')

    $gpuMemOld = if ($gpuMemMatch.Success) { $gpuMemMatch.Groups[1].Value } else { "N/A" }
    $gpuLevelOld = if ($gpuLevelMatch.Success) { $gpuLevelMatch.Groups[1].Value } else { "N/A" }

    $backupData += [PSCustomObject]@{
        FilePath    = $f.FullName
        UserId      = $userId
        GpuMemLevel = $gpuMemOld
        GpuLevel    = $gpuLevelOld
    }

    $content = $content -replace '("setting\.gpu_mem_level"\s+)"\d+"', '$1"0"'
    $content = $content -replace '("setting\.gpu_level"\s+)"\d+"', '$1"0"'

    [System.IO.File]::WriteAllText($f.FullName, $content, [System.Text.UTF8Encoding]::new($false))

    Write-Host "已修改: 用户 $userId (gpu_mem_level: $gpuMemOld → 0, gpu_level: $gpuLevelOld → 0)" -ForegroundColor Green
}

$backupJson = $backupData | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($backupFile, $backupJson, [System.Text.UTF8Encoding]::new($false))
Write-Host ""
Write-Host "备份已保存至: $backupFile" -ForegroundColor Green
Write-Host ""
Write-Host "====== 修改完成 ======" -ForegroundColor Cyan
Write-Host ""
Write-Host "如需还原，请运行 Restore-CS2Video.cmd" -ForegroundColor Green
Write-Host ""
pause
