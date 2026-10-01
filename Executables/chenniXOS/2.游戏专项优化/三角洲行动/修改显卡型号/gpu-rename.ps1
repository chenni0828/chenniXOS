<#
  gpu-rename.ps1 - 显卡型号修改工具
  修改显示适配器在注册表中的 DeviceDesc 显示名称。
  修改前自动备份，支持恢复原始名称。
  由 gpu-rename.bat 启动。
#>

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Host.UI.RawUI.WindowTitle = '显卡型号修改工具'

# 检查管理员权限
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 0
}

# ---------- 输出辅助 ----------
function Write-Banner {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "               显卡型号修改工具" -ForegroundColor Cyan
    Write-Host "         修改注册表中的显卡显示名称" -ForegroundColor DarkCyan
    Write-Host "=====================================================" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Step, [string]$Title)
    Write-Host ""
    Write-Host "  ┌─ $Step ─────────────────────────────" -ForegroundColor Cyan
    Write-Host "  │ $Title" -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Msg)
    Write-Host "  [+] $Msg" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Msg)
    Write-Host "  [!] $Msg" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Msg)
    Write-Host "  [x] $Msg" -ForegroundColor Red
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  $Msg" -ForegroundColor DarkGray
}

# ---------- 数据 ----------
$gpuPresets = @(
    @{Category="N卡"; Name="NVIDIA GeForce GTX 750 Ti";  LaptopNote=$true},
    @{Category="N卡"; Name="NVIDIA GeForce GTX 1050 Ti"; LaptopNote=$false},
    @{Category="A卡"; Name="AMD Radeon RX 560";          LaptopNote=$false},
    @{Category="A卡"; Name="AMD Radeon RX R9 270X";      LaptopNote=$false}
)

function Get-DisplayAdapterInfo {
    param([string]$InstanceId)
    $regPath = "Registry::HKLM\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    try {
        $desc = (Get-ItemProperty -Path $regPath -Name 'DeviceDesc' -ErrorAction Stop).DeviceDesc
        if ($desc -match ';([^;]+)$') {
            return @{ FullDesc = $desc; DisplayName = $matches[1].Trim() }
        } else {
            return @{ FullDesc = $desc; DisplayName = $desc }
        }
    } catch {
        return $null
    }
}

function Get-BackupFiles {
    param([string]$BackupDir)
    $files = @()
    foreach ($f in (Get-ChildItem -Path $BackupDir -Filter 'gpu-rename_backup_*.txt' -ErrorAction SilentlyContinue)) {
        try {
            $content = Get-Content -Path $f.FullName -Encoding UTF8 -Raw -ErrorAction Stop
            $instMatch = [regex]::Match($content, '设备实例路径:\s*(.+)')
            $descMatch = [regex]::Match($content, 'DeviceDesc=(.+)')
            $instanceId = if ($instMatch.Success) { $instMatch.Groups[1].Value.Trim() } else { '未知' }
            $origName = if ($descMatch.Success) {
                $v = $descMatch.Groups[1].Value.Trim()
                if ($v -match ';([^;]+)$') { $matches[1].Trim() } else { $v }
            } else { '未知' }
            $files += [pscustomobject]@{
                FilePath = $f.FullName
                FileName = $f.Name
                InstanceId = $instanceId
                OriginalName = $origName
                BackupTime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
        } catch {}
    }
    return $files
}

function Confirm-Action {
    param([string]$Prompt = "确认执行")
    Write-Host ""
    $ans = Read-Host "  $Prompt ? (Y/N)"
    return ($ans.Trim() -eq 'Y' -or $ans.Trim() -eq 'y')
}

function Prompt-Restart {
    Write-Host ""
    Write-Warn "需要重启电脑才能使修改生效"
    $ans = Read-Host "  是否立即重启? (Y/N)"
    if ($ans.Trim() -eq 'Y' -or $ans.Trim() -eq 'y') {
        Restart-Computer -Force
    } else {
        Write-Info "请稍后手动重启电脑以应用更改"
    }
}

# ===================== 主菜单 =====================
Write-Banner

Write-Host ""
Write-Host "  [1] 修改显卡型号    检测显卡 -> 选择型号 -> 备份并修改" -ForegroundColor White
Write-Host "  [2] 恢复原始型号    从备份还原显卡原始名称" -ForegroundColor White
Write-Host "  [0] 退出" -ForegroundColor White
Write-Host ""
$menuChoice = Read-Host "  请输入序号"

if ($menuChoice -eq '0') {
    Write-Host "  已退出。"
    exit 0
}

# =====================================================================
# 修改模式
# =====================================================================
if ($menuChoice -eq '1') {

    # --- Step 1: 检测显示适配器 ---
    Write-Step "Step 1/4" "检测显示适配器"
    Write-Host "  正在扫描 PCI 显示设备..." -ForegroundColor DarkGray

    $pnpDevices = Get-PnpDevice -Class Display | Where-Object {
        $_.Status -eq 'OK' -and $_.InstanceId -match '^PCI\\'
    }

    if ($pnpDevices.Count -eq 0) {
        Write-Err "未检测到 PCI 显示适配器"
        exit 1
    }

    $adapters = @()
    $idx = 1
    Write-Host ""
    foreach ($dev in $pnpDevices) {
        $info = Get-DisplayAdapterInfo -InstanceId $dev.InstanceId
        $displayName = if ($info) { $info.DisplayName } else { $dev.FriendlyName }
        $adapters += [pscustomobject]@{
            Index      = $idx
            InstanceId = $dev.InstanceId
            Name       = $displayName
            FullDesc   = if ($info) { $info.FullDesc } else { $displayName }
        }
        Write-Host ("    [{0}] {1}" -f $idx, $displayName) -ForegroundColor White
        Write-Host ("        {0}" -f $dev.InstanceId) -ForegroundColor DarkGray
        $idx++
    }

    Write-Host ""
    $sel = Read-Host "  选择要修改的显卡"
    $selIdx = 0
    if (-not ([int]::TryParse($sel, [ref]$selIdx)) -or $selIdx -lt 1 -or $selIdx -gt $adapters.Count) {
        Write-Warn "无效选择，退出"
        exit 0
    }
    $selectedAdapter = $adapters[$selIdx - 1]
    Write-Done "已选择: $($selectedAdapter.Name)"

    # --- Step 2: 选择目标型号 ---
    Write-Step "Step 2/4" "选择目标显卡型号"

    Write-Host ""
    Write-Host "  ── N卡 ──────────────────────────────────" -ForegroundColor DarkCyan
    $nIdx = 0
    for ($i = 0; $i -lt $gpuPresets.Count; $i++) {
        if ($gpuPresets[$i].Category -eq 'N卡') {
            $nIdx++
            $line = "  [$($i+1)] $($gpuPresets[$i].Name)"
            if ($gpuPresets[$i].LaptopNote) {
                $line += "  * 笔记本不支持"
            }
            Write-Host $line -ForegroundColor White
        }
    }
    Write-Host "  ── A卡 ──────────────────────────────────" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $gpuPresets.Count; $i++) {
        if ($gpuPresets[$i].Category -eq 'A卡') {
            $line = "  [$($i+1)] $($gpuPresets[$i].Name)"
            Write-Host $line -ForegroundColor White
        }
    }
    Write-Host "  ── 自定义 ───────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  [5] 手动输入显卡名称" -ForegroundColor White
    Write-Host ""

    $gpuSel = Read-Host "  选择目标型号 (1-5)"
    $gpuIdx = 0
    if (-not ([int]::TryParse($gpuSel, [ref]$gpuIdx)) -or $gpuIdx -lt 1 -or $gpuIdx -gt 5) {
        Write-Warn "无效选择，退出"
        exit 0
    }

    if ($gpuIdx -eq 5) {
        $targetName = Read-Host "  输入自定义显卡名称"
        if ([string]::IsNullOrWhiteSpace($targetName)) {
            Write-Err "显卡名称不能为空"
            exit 1
        }
    } else {
        $targetName = $gpuPresets[$gpuIdx - 1].Name
    }

    # --- Step 3: 确认变更 ---
    Write-Step "Step 3/4" "确认变更内容"
    Write-Host ""
    Write-Host "  当前名称: $($selectedAdapter.Name)" -ForegroundColor White
    Write-Host "              |" -ForegroundColor DarkGray
    Write-Host "              v" -ForegroundColor DarkGray
    Write-Host "  目标名称: $targetName" -ForegroundColor Yellow
    Write-Host ""
    Write-Info "注册表: HKLM\SYSTEM\CurrentControlSet\Enum\$($selectedAdapter.InstanceId)"

    if (-not (Confirm-Action "确认修改")) {
        Write-Host "  已取消，未做改动"
        exit 0
    }

    # --- Step 4: 备份并修改 ---
    Write-Step "Step 4/4" "备份并修改注册表"

    $regPath = "Registry::HKLM\SYSTEM\CurrentControlSet\Enum\$($selectedAdapter.InstanceId)"
    $safeId = $selectedAdapter.InstanceId -replace '[\\/:\*\?"<>\|]', '_'
    $backupFile = Join-Path $scriptDir "gpu-rename_backup_$safeId.txt"

    $hasDeviceDescName = $false
    $deviceDescNameValue = ''

    try {
        $deviceDescFull = (Get-ItemProperty -Path $regPath -Name 'DeviceDesc' -ErrorAction Stop).DeviceDesc
    } catch {
        Write-Err "读取 DeviceDesc 失败: $_"
        exit 1
    }

    try {
        $deviceDescNameValue = (Get-ItemProperty -Path $regPath -Name 'DeviceDescName' -ErrorAction Stop).DeviceDescName
        $hasDeviceDescName = $true
    } catch {
        Write-Info "DeviceDescName 不存在，仅修改 DeviceDesc"
    }

    # 备份
    $backupContent = @"
# 显卡型号备份文件
# 备份时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# 设备实例路径: $($selectedAdapter.InstanceId)

DeviceDesc=$deviceDescFull
"@
    if ($hasDeviceDescName) {
        $backupContent += "`r`nDeviceDescName=$deviceDescNameValue"
    }

    try {
        [System.IO.File]::WriteAllText($backupFile, $backupContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Done "备份已保存"
        Write-Info $backupFile
    } catch {
        Write-Err "备份写入失败: $_"
        exit 1
    }

    # 修改
    try {
        Set-ItemProperty -Path $regPath -Name 'DeviceDesc' -Value $targetName -ErrorAction Stop
        Write-Done "DeviceDesc  -> $targetName"

        if ($hasDeviceDescName) {
            Set-ItemProperty -Path $regPath -Name 'DeviceDescName' -Value $targetName -ErrorAction Stop
            Write-Done "DeviceDescName -> $targetName"
        }
    } catch {
        Write-Err "修改注册表失败: $_"
        exit 1
    }

    # --- 完成 ---
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor Green
    Write-Host "    修改完成" -ForegroundColor Green
    Write-Host "    $($selectedAdapter.Name)  ->  $targetName" -ForegroundColor White
    Write-Host "  =====================================================" -ForegroundColor Green
    Write-Info "如需恢复，请重新运行脚本选择 [2] 恢复原始型号"

    Prompt-Restart
}

# =====================================================================
# 恢复模式
# =====================================================================
elseif ($menuChoice -eq '2') {

    # --- Step 1: 选择备份 ---
    Write-Step "Step 1/3" "选择备份文件"
    $backups = Get-BackupFiles -BackupDir $scriptDir

    if ($backups.Count -eq 0) {
        Write-Warn "未找到任何备份文件"
        exit 0
    }

    Write-Host ""
    Write-Host "  找到 $($backups.Count) 个备份:" -ForegroundColor White
    Write-Host ""
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b = $backups[$i]
        Write-Host ("    [{0}] {1}" -f ($i + 1), $b.OriginalName) -ForegroundColor White
        Write-Host ("        备份时间: {0}" -f $b.BackupTime) -ForegroundColor DarkGray
        Write-Host ("        设备路径: {0}" -f $b.InstanceId) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "    [0] 返回" -ForegroundColor White
    Write-Host ""

    $sel = Read-Host "  选择要恢复的备份"
    $selIdx = 0
    if (-not ([int]::TryParse($sel, [ref]$selIdx)) -or $selIdx -lt 0 -or $selIdx -gt $backups.Count) {
        Write-Warn "无效选择，退出"
        exit 0
    }
    if ($selIdx -eq 0) {
        Write-Host "  已返回"
        exit 0
    }

    $selectedBackup = $backups[$selIdx - 1]

    # 解析备份内容
    try {
        $bkContent = [System.IO.File]::ReadAllText($selectedBackup.FilePath, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Err "读取备份文件失败: $_"
        exit 1
    }

    $origDeviceDesc = [regex]::Match($bkContent, 'DeviceDesc=(.+)').Groups[1].Value.Trim()
    $origDeviceDescName = [regex]::Match($bkContent, 'DeviceDescName=(.+)').Groups[1].Value.Trim()

    if ([string]::IsNullOrEmpty($origDeviceDesc)) {
        Write-Err "备份文件内容异常，无法解析 DeviceDesc"
        exit 1
    }

    # --- Step 2: 确认恢复 ---
    Write-Step "Step 2/3" "确认恢复内容"
    Write-Host ""
    Write-Host "  恢复为: $($selectedBackup.OriginalName)" -ForegroundColor Yellow
    Write-Host ""
    if ($origDeviceDescName) {
        Write-Info "DeviceDesc:     $origDeviceDesc"
        Write-Info "DeviceDescName: $origDeviceDescName"
    } else {
        Write-Info "DeviceDesc: $origDeviceDesc"
    }
    Write-Info "注册表: HKLM\SYSTEM\CurrentControlSet\Enum\$($selectedBackup.InstanceId)"

    if (-not (Confirm-Action "确认恢复")) {
        Write-Host "  已取消，未做改动"
        exit 0
    }

    # --- Step 3: 恢复注册表 ---
    Write-Step "Step 3/3" "恢复注册表"
    $regPath = "Registry::HKLM\SYSTEM\CurrentControlSet\Enum\$($selectedBackup.InstanceId)"

    try {
        Set-ItemProperty -Path $regPath -Name 'DeviceDesc' -Value $origDeviceDesc -ErrorAction Stop
        Write-Done "DeviceDesc 已恢复"

        if ($origDeviceDescName) {
            try {
                Set-ItemProperty -Path $regPath -Name 'DeviceDescName' -Value $origDeviceDescName -ErrorAction Stop
                Write-Done "DeviceDescName 已恢复"
            } catch {
                Write-Warn "恢复 DeviceDescName 失败: $_"
            }
        }
    } catch {
        Write-Err "恢复注册表失败: $_"
        exit 1
    }

    try {
        Remove-Item -Path $selectedBackup.FilePath -Force -ErrorAction Stop
        Write-Done "备份文件已删除"
    } catch {
        Write-Warn "删除备份文件失败: $_"
    }

    # --- 完成 ---
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor Green
    Write-Host "    恢复完成" -ForegroundColor Green
    Write-Host "    显卡型号已恢复为: $($selectedBackup.OriginalName)" -ForegroundColor White
    Write-Host "  =====================================================" -ForegroundColor Green

    Prompt-Restart
}

else {
    Write-Warn "无效选择，退出"
    exit 0
}

Write-Host ""