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

$gpus = @(Get-PnpDevice -Class Display -EA 0 | Where-Object { $_.InstanceId -like "PCI\*" })
if ($gpus.Count -eq 0) {
    $gpus = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.PNPDeviceID -like "PCI\*" })
    if ($gpus.Count -eq 0) {
        Write-Host "未检测到任何 PCI 显卡。" -ForegroundColor Red
        pause
        exit 1
    }
}

$isNotebook = $false
try {
    $chassis = (Get-CimInstance -ClassName Win32_SystemEnclosure -EA 0).ChassisTypes
    if ($chassis) {
        $notebookTypes = @(8,9,10,11,12,14,18,21)
        $isNotebook = ($chassis | Where-Object { $_ -in $notebookTypes }).Count -gt 0
    }
} catch {}
if (-not $isNotebook) {
    try {
        $pcType = (Get-CimInstance -ClassName Win32_ComputerSystem -EA 0).PCSystemType
        $isNotebook = ($pcType -eq 2)
    } catch {}
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   显卡型号改名工具 (三角洲行动)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "检测到以下显卡：" -ForegroundColor Yellow
$idx = 1
foreach ($gpu in $gpus) {
    $name = if ($gpu.Name) { $gpu.Name } else { $gpu.FriendlyName }
    $id = if ($gpu.InstanceId) { $gpu.InstanceId } else { $gpu.PNPDeviceID }
    Write-Host "  [$idx] $name" -ForegroundColor White
    Write-Host "      实例: $id" -ForegroundColor DarkGray
    $idx++
}

Write-Host ""
Write-Host "请选择要修改为的显卡型号：" -ForegroundColor Yellow
Write-Host "  [0] 不更改（默认）" -ForegroundColor Green
Write-Host "  [1] NVIDIA GeForce GTX 750 Ti"
if ($isNotebook) { Write-Host "      ⚠ 笔记本无此型号，请选择 1050 Ti" -ForegroundColor Red }
Write-Host "  [2] NVIDIA GeForce GTX 1050 Ti"
Write-Host "  [3] AMD Radeon RX 560"
Write-Host "  [4] AMD Radeon RX R9 270X"
Write-Host ""

$presets = @(
    "NVIDIA GeForce GTX 750 Ti",
    "NVIDIA GeForce GTX 1050 Ti",
    "AMD Radeon RX 560",
    "AMD Radeon RX R9 270X"
)

$choice = Read-Host "输入编号 (0-4)"
if ($choice -eq "0" -or $choice -eq "") {
    Write-Host "未更改，退出。" -ForegroundColor Yellow
    pause
    exit 0
}

if ([int]$choice -ge 1 -and [int]$choice -le 4) {
    $targetName = $presets[[int]$choice - 1]
} else {
    Write-Host "无效选择，退出。" -ForegroundColor Red
    pause
    exit 1
}

if ($isNotebook -and $targetName -like "*750 Ti*") {
    Write-Host ""
    Write-Host "⚠ 警告：检测到笔记本，NVIDIA GeForce GTX 750 Ti 仅限台式机！" -ForegroundColor Red
    Write-Host "笔记本没有 750 Ti 型号，建议选择 1050 Ti。" -ForegroundColor Yellow
    $confirm = Read-Host "是否仍然继续？(y/N)"
    if ($confirm -notmatch '^[yY]') { pause; exit 0 }
}

Write-Host ""
Write-Host "即将修改为: $targetName" -ForegroundColor Green
$confirm = Read-Host "确认修改？(y/N)"
if ($confirm -notmatch '^[yY]') { Write-Host "已取消。"; pause; exit 0 }

$backupData = @()
foreach ($gpu in $gpus) {
    $instancePath = if ($gpu.InstanceId) { $gpu.InstanceId } elseif ($gpu.PNPDeviceID) { $gpu.PNPDeviceID } else { "" }
    if (-not $instancePath) { continue }

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instancePath"
    $name = if ($gpu.Name) { $gpu.Name } else { $gpu.FriendlyName }

    if (-not (Test-Path $regPath)) {
        Write-Host "警告: 注册表路径不存在 ($name)，跳过。" -ForegroundColor Yellow
        continue
    }

    $valueName = $null
    $originalValue = $null
    foreach ($vn in @("DeviceDesc", "Device Desc Name", "DeviceDescName")) {
        $prop = Get-ItemProperty -Path $regPath -Name $vn -EA 0
        if ($prop -and $prop.$vn) {
            $valueName = $vn
            $originalValue = $prop.$vn
            break
        }
    }

    if (-not $valueName) {
        Write-Host "警告: $name 未找到 DeviceDesc / Device Desc Name / DeviceDescName，跳过。" -ForegroundColor Yellow
        continue
    }

    $backupData += [PSCustomObject]@{
        InstancePath = $instancePath
        ValueName    = $valueName
        Original     = $originalValue
        GPUName      = $name
    }
}

if ($backupData.Count -eq 0) {
    Write-Host "没有可修改的显卡注册表项，退出。" -ForegroundColor Red
    pause
    exit 1
}

$backupJson = $backupData | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($backupFile, $backupJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "备份已保存至: $backupFile" -ForegroundColor Green

foreach ($entry in $backupData) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($entry.InstancePath)"

    try {
        Set-ItemProperty -Path $regPath -Name $entry.ValueName -Value $targetName -Type String -EA Stop
    } catch {
        Write-Host "权限不足，尝试获取注册表权限..." -ForegroundColor Yellow
        Grant-EnumKeyAccess -RegPath $regPath | Out-Null
        Set-ItemProperty -Path $regPath -Name $entry.ValueName -Value $targetName -Type String
    }
    Write-Host "已修改: $targetName" -ForegroundColor Green
}

Write-Host ""
Write-Host "====== 修改完成 ======" -ForegroundColor Cyan
Write-Host ""
Write-Host "⚠ 重要提醒：" -ForegroundColor Yellow
Write-Host "1. 请进入游戏后手动重新预热/编译着色器" -ForegroundColor White
Write-Host "2. 需要重启电脑使更改生效" -ForegroundColor White
Write-Host ""
Write-Host "如需还原，请运行 Restore-GPUName.cmd" -ForegroundColor Green
Write-Host ""

$restart = Read-Host "是否立即重启电脑？(y/N)"
if ($restart -match '^[yY]') {
    Restart-Computer -Force
} else {
    Write-Host "请稍后手动重启电脑。" -ForegroundColor Yellow
}
