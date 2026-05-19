$ErrorActionPreference = "Stop"
$scriptDir = "$PSScriptRoot"
$backupFile = "$scriptDir\GPUNameBackup.txt"

function Grant-EnumKeyAccess {
    param([string]$RegPath)
    try {
        $acl = Get-Acl -Path $RegPath -EA Stop
        $adminRule = New-Object System.Security.AccessControl.RegistryAccessRule(
            "BUILTIN\Administrators", "FullControl", "ContainerInherit", "None", "Allow"
        )
        $acl.AddAccessRule($adminRule)
        Set-Acl -Path $RegPath -AclObject $acl
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-Path $backupFile)) {
    Write-Host "未找到备份文件: $backupFile" -ForegroundColor Red
    Write-Host "请先运行 Change-GPUName.cmd 进行修改后再还原。"
    pause
    exit 1
}

$backupJson = [System.IO.File]::ReadAllText($backupFile, [System.Text.UTF8Encoding]::new($false))
$backupData = $backupJson | ConvertFrom-Json

if ($backupData -isnot [System.Array]) {
    $backupData = @($backupData)
}

foreach ($entry in $backupData) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($entry.InstancePath)"

    if (-not (Test-Path $regPath)) {
        Write-Host "警告: 注册表路径不存在 ($($entry.InstancePath))，跳过。" -ForegroundColor Yellow
        continue
    }

    try {
        Set-ItemProperty -Path $regPath -Name $entry.ValueName -Value $entry.Original -Type String -EA Stop
    } catch {
        Write-Host "权限不足，尝试获取注册表权限..." -ForegroundColor Yellow
        Grant-EnumKeyAccess -RegPath $regPath | Out-Null
        Set-ItemProperty -Path $regPath -Name $entry.ValueName -Value $entry.Original -Type String
    }
    Write-Host "已还原: $($entry.GPUName)" -ForegroundColor Green
    Write-Host "  $($entry.ValueName) = $($entry.Original)" -ForegroundColor DarkGray
}

Remove-Item $backupFile -Force
Write-Host ""
Write-Host "还原完成！" -ForegroundColor Cyan
Write-Host "需要重启电脑使更改生效" -ForegroundColor Yellow
Write-Host ""

$restart = Read-Host "是否立即重启电脑？(y/N)"
if ($restart -match '^[yY]') {
    Restart-Computer -Force
} else {
    Write-Host "请稍后手动重启电脑。" -ForegroundColor Yellow
}
