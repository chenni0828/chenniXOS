<#
  cs2-video.ps1 - CS2 Video 配置优化工具
  将 cs2_video.txt 中 setting.gpu_mem_level 与 setting.gpu_level 设为 0，
  原始值备份到脚本同目录。已优化且备份存在时可恢复。
  由 cs2-video.bat 启动。
#>

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Host.UI.RawUI.WindowTitle = 'CS2 Video 配置优化工具'

# SteamID3 -> SteamID64 的固定偏移量
$SteamId64Base = [uint64]76561197960265728

function Write-Banner {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "             CS2 Video 配置优化工具" -ForegroundColor Cyan
    Write-Host "         gpu_mem_level / gpu_level -> 0" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "[ $Title ]" -ForegroundColor Green
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

function Get-SteamPath {
    $steamPath = $null
    # 1. HKCU
    try {
        $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction Stop).SteamPath
        if ($p) { $steamPath = $p }
    } catch {}
    # 2. HKLM WOW6432Node
    if (-not $steamPath) {
        try {
            $p = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name 'InstallPath' -ErrorAction Stop).InstallPath
            if ($p) { $steamPath = $p }
        } catch {}
    }
    # 3. HKLM 直读
    if (-not $steamPath) {
        try {
            $p = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Valve\Steam' -Name 'InstallPath' -ErrorAction Stop).InstallPath
            if ($p) { $steamPath = $p }
        } catch {}
    }

    # 统一为反斜杠并去尾部分隔符，便于显示与拼接
    if ($steamPath) {
        $steamPath = ($steamPath -replace '/', '\').TrimEnd('\')
        if (Test-Path (Join-Path $steamPath 'userdata')) {
            return $steamPath
        }
    }

    # 4. 手动输入
    Write-Host ""
    if ($steamPath) {
        Write-Warn "注册表中找到 Steam 路径 '$steamPath'，但该目录下无 userdata 文件夹。"
    } else {
        Write-Warn "未能在注册表自动定位 Steam 安装目录。"
    }
    while ($true) {
        $inp = Read-Host "  请输入 Steam 安装目录完整路径（留空取消）"
        if ([string]::IsNullOrWhiteSpace($inp)) { return $null }
        $inp = ($inp.Trim().Trim('"') -replace '/', '\').TrimEnd('\')
        if ((Test-Path $inp) -and (Test-Path (Join-Path $inp 'userdata'))) {
            return $inp
        }
        Write-Warn "路径无效或不含 userdata 文件夹，请重试。"
    }
}

function Get-AccountNameMap {
    param([string]$SteamPath)
    $map = @{}
    $vdf = Join-Path $SteamPath 'config\loginusers.vdf'
    if (-not (Test-Path $vdf)) { return $map }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($vdf)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $content = [System.Text.Encoding]::Unicode.GetString($bytes)
        } else {
            # Steam 的 loginusers.vdf 通常为 UTF-8（带或不带 BOM）
            $content = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
        }
        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
        # 匹配每个 SteamID64 块（允许 } 出现在引号字符串内，如含特殊字符的账号名）
        $blockPattern = '"(\d{17})"\s*\{((?:[^}"]|"[^"]*")*)\}'
        foreach ($m in [regex]::Matches($content, $blockPattern)) {
            $sid64 = $m.Groups[1].Value
            $block = $m.Groups[2].Value
            # 优先 PersonaName（新版 Steam），回退 AccountName，再回退旧字段名 Persona/Account
            $name = $null
            foreach ($field in @('PersonaName', 'AccountName', 'Persona', 'Account')) {
                $fm = [regex]::Match($block, '"' + $field + '"\s+"([^"]*)"')
                if ($fm.Success) { $name = $fm.Groups[1].Value; break }
            }
            if ($name) { $map[$sid64] = $name }
        }
    } catch {}
    return $map
}

function Read-VideoFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding($true)
    } else {
        $enc = New-Object System.Text.UTF8Encoding($false)
    }
    $content = $enc.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    return @{ Content = $content; Encoding = $enc }
}

function Get-VideoValue {
    param([string]$Content, [string]$Key)
    $m = [regex]::Match($Content, '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-VideoValue {
    param([string]$Content, [string]$Key, [string]$NewValue)
    $pattern = '("' + [regex]::Escape($Key) + '"\s+")[^"]*(")'
    $replacement = '${1}' + $NewValue + '${2}'
    return [regex]::Replace($Content, $pattern, $replacement)
}

# ===== 主流程 =====
Write-Banner

# --- 定位 Steam ---
Write-Section "Steam 安装目录"
Write-Host "  正在自动读取注册表..."
$steamPath = Get-SteamPath
if (-not $steamPath) {
    Write-Warn "已取消。"
    exit 0
}
Write-Done $steamPath

# --- 扫描账号 ---
Write-Section "CS2 账号列表"
$userdataDir = Join-Path $steamPath 'userdata'
$accounts = @()
try {
    $nameMap = Get-AccountNameMap -SteamPath $steamPath
    foreach ($dir in (Get-ChildItem -Path $userdataDir -Directory -ErrorAction Stop)) {
        $acctId = $dir.Name
        if ($acctId -match '^\d+$') {
            $videoFile = Join-Path $dir.FullName '730\local\cfg\cs2_video.txt'
            if (Test-Path $videoFile) {
                $steamId64 = [uint64]$acctId + $SteamId64Base
                $dispName = $nameMap[[string]$steamId64]
                if (-not $dispName) { $dispName = '未知账号' }
                $accounts += [pscustomobject]@{ Id = $acctId; Name = $dispName; VideoFile = $videoFile }
            }
        }
    }
} catch {
    Write-Err "扫描 userdata 目录失败: $_"
    exit 1
}

if ($accounts.Count -eq 0) {
    Write-Warn "未找到任何含 cs2_video.txt 的 CS2 账号。"
    Write-Warn "请确认已通过 Steam 登录并启动过 CS2。"
    exit 0
}

Write-Host "  找到 $($accounts.Count) 个含 cs2_video.txt 的账号：" -ForegroundColor White
Write-Host ""
for ($i = 0; $i -lt $accounts.Count; $i++) {
    Write-Host ("    [{0}] {1}    (ID: {2})" -f ($i + 1), $accounts[$i].Name, $accounts[$i].Id)
}
Write-Host "    [0] 退出"
Write-Host ""
$sel = Read-Host "  请输入序号"
$idx = 0
if (-not ([int]::TryParse($sel, [ref]$idx)) -or $idx -lt 0 -or $idx -gt $accounts.Count) {
    Write-Warn "无效选择，退出。"
    exit 0
}
if ($idx -eq 0) {
    Write-Host "  已退出。"
    exit 0
}
$acct = $accounts[$idx - 1]

# --- 读取当前配置 ---
Write-Section "当前配置  $($acct.Name) (ID: $($acct.Id))"
$videoFile = $acct.VideoFile
try {
    $fileData = Read-VideoFile -Path $videoFile
} catch {
    Write-Err "读取 cs2_video.txt 失败: $_"
    exit 1
}
$memVal = Get-VideoValue -Content $fileData.Content -Key 'setting.gpu_mem_level'
$gpuVal = Get-VideoValue -Content $fileData.Content -Key 'setting.gpu_level'

if ($null -eq $memVal -or $null -eq $gpuVal) {
    Write-Err "未能从 cs2_video.txt 中解析出 gpu_mem_level 或 gpu_level，文件格式可能异常。"
    exit 1
}

Write-Host "  gpu_mem_level = $memVal"
Write-Host "  gpu_level     = $gpuVal"

$backupFile = Join-Path $scriptDir ("cs2-video_backup_{0}.txt" -f $acct.Id)
$backupExists = Test-Path $backupFile

# --- 操作选择 ---
$bothZero = ($memVal -eq '0' -and $gpuVal -eq '0')

if ($bothZero -and $backupExists) {
    # 已优化 + 有备份 -> 询问是否恢复
    Write-Section "操作选择"
    Write-Warn "检测到两个值已为 0，且存在备份文件。"
    Write-Host "  备份文件: $backupFile" -ForegroundColor White
    $ans = Read-Host "  是否恢复原始值？(Y/N)"
    if ($ans.Trim() -ne 'Y' -and $ans.Trim() -ne 'y') {
        Write-Host "  已取消，未做改动。"
        exit 0
    }
    try {
        $bkContent = [System.IO.File]::ReadAllText($backupFile, (New-Object System.Text.UTF8Encoding($false)))
        $origMem = [regex]::Match($bkContent, 'gpu_mem_level=(\d+)').Groups[1].Value
        $origGpu = [regex]::Match($bkContent, 'gpu_level=(\d+)').Groups[1].Value
        if ([string]::IsNullOrEmpty($origMem) -or [string]::IsNullOrEmpty($origGpu)) {
            Write-Err "备份文件内容异常，无法解析原始值。"
            exit 1
        }
        $newContent = Set-VideoValue -Content $fileData.Content -Key 'setting.gpu_mem_level' -NewValue $origMem
        $newContent = Set-VideoValue -Content $newContent -Key 'setting.gpu_level' -NewValue $origGpu
        [System.IO.File]::WriteAllText($videoFile, $newContent, $fileData.Encoding)
        Remove-Item -Path $backupFile -Force
        Write-Host ""
        Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
        Write-Done "恢复完成"
        Write-Host "  gpu_mem_level: 0 -> $origMem" -ForegroundColor White
        Write-Host "  gpu_level:     0 -> $origGpu" -ForegroundColor White
        Write-Host "  备份文件已删除" -ForegroundColor White
        Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
    } catch {
        Write-Err "恢复失败: $_"
        exit 1
    }
}
elseif ($bothZero -and -not $backupExists) {
    # 已优化 + 无备份 -> 无需操作
    Write-Section "操作选择"
    Write-Warn "两个值已为 0，未找到备份文件，无需操作。"
    exit 0
}
else {
    # 非零 -> 询问是否优化
    Write-Section "操作选择"
    Write-Host "  当前值非 0，可应用优化（设为 0 并备份原值）。" -ForegroundColor White
    if ($backupExists) {
        Write-Warn "已存在旧的备份文件，将被覆盖。"
    }
    $ans = Read-Host "  是否应用优化？(Y/N)"
    if ($ans.Trim() -ne 'Y' -and $ans.Trim() -ne 'y') {
        Write-Host "  已取消，未做改动。"
        exit 0
    }
    try {
        $bkText = "gpu_mem_level=$memVal`r`ngpu_level=$gpuVal`r`n"
        [System.IO.File]::WriteAllText($backupFile, $bkText, (New-Object System.Text.UTF8Encoding($false)))
        $newContent = Set-VideoValue -Content $fileData.Content -Key 'setting.gpu_mem_level' -NewValue '0'
        $newContent = Set-VideoValue -Content $newContent -Key 'setting.gpu_level' -NewValue '0'
        [System.IO.File]::WriteAllText($videoFile, $newContent, $fileData.Encoding)
        Write-Host ""
        Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
        Write-Done "优化完成"
        Write-Host "  gpu_mem_level: $memVal -> 0" -ForegroundColor White
        Write-Host "  gpu_level:     $gpuVal -> 0" -ForegroundColor White
        Write-Host "  备份: cs2-video_backup_$($acct.Id).txt" -ForegroundColor White
        Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
    } catch {
        Write-Err "优化失败: $_"
        exit 1
    }
}

Write-Host ""
