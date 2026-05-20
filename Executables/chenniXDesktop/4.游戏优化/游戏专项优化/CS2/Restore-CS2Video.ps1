$ErrorActionPreference = "Stop"
$scriptDir = "$PSScriptRoot"
$backupFile = "$scriptDir\CS2VideoBackup.txt"

if (-not (Test-Path $backupFile)) {
    Write-Host "未找到备份文件: $backupFile" -ForegroundColor Red
    Write-Host "请先运行 Optimize-CS2Video.cmd 进行修改后再还原。"
    pause
    exit 1
}

$backupJson = [System.IO.File]::ReadAllText($backupFile, [System.Text.UTF8Encoding]::new($false))
$backupData = $backupJson | ConvertFrom-Json

if ($backupData -isnot [System.Array]) {
    $backupData = @($backupData)
}

foreach ($entry in $backupData) {
    if (-not (Test-Path $entry.FilePath)) {
        Write-Host "警告: 配置文件不存在 ($($entry.FilePath))，跳过。" -ForegroundColor Yellow
        continue
    }

    $content = [System.IO.File]::ReadAllText($entry.FilePath, [System.Text.UTF8Encoding]::new($false))

    if ($entry.GpuMemLevel -ne "N/A") {
        $content = $content -replace '("setting\.gpu_mem_level"\s+)"\d+"', "`$1`"$($entry.GpuMemLevel)`""
    }
    if ($entry.GpuLevel -ne "N/A") {
        $content = $content -replace '("setting\.gpu_level"\s+)"\d+"', "`$1`"$($entry.GpuLevel)`""
    }

    [System.IO.File]::WriteAllText($entry.FilePath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "已还原: 用户 $($entry.UserId) (gpu_mem_level=$($entry.GpuMemLevel), gpu_level=$($entry.GpuLevel))" -ForegroundColor Green
}

Remove-Item $backupFile -Force
Write-Host ""
Write-Host "还原完成！" -ForegroundColor Cyan
Write-Host ""
pause
