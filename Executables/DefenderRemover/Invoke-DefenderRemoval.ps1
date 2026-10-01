# Adapted from ionuttbara/windows-defender-remover, release13-rev1 (commit 6126092a5376753153295a20806ebd2f5f3e1c0e).
# Upstream removal data is licensed under CC BY-NC 4.0; see LICENSE.
# StopDefender.ps1 preserves the working v0.1.0 implementation and its MIT attribution.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Stop', 'Wait', 'RemoveApp', 'Registry', 'UserRegistry', 'Tasks', 'Files', 'Finalize', 'Startup')]
    [string]$Stage,
    [switch]$AfterRestart
)

$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:ProgramData 'chenniXOS\DefenderRemover'
$payloadRoot = Join-Path $stateRoot 'Payload'
$phaseRoot = Join-Path $stateRoot 'Stages'
$logPath = Join-Path $stateRoot 'DefenderRemoval.log'
$resultPath = Join-Path $stateRoot 'Result.json'
$manifestPath = Join-Path $stateRoot 'Targets.json'
$operationPath = Join-Path $stateRoot 'Operation.json'
$taskName = 'chenniXOS-DefenderCleanup'
$defenderTaskPath = '\Microsoft\Windows\Windows Defender'
$taskCacheRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache'
$taskTreePath = $taskCacheRoot + '\Tree\Microsoft\Windows\Windows Defender'
$taskFilesPath = Join-Path $env:WINDIR 'System32\Tasks\Microsoft\Windows\Windows Defender'
$serviceNames = @('MDCoreSvc', 'WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot',
    'Sense', 'SecurityHealthService', 'wscsvc', 'MsSecCore', 'MsSecFlt', 'MsSecWfp',
    'SgrmBroker', 'SgrmAgent', 'webthreatdefsvc', 'webthreatdefusersvc', 'whesvc',
    'PlutonHsp2', 'PlutonHeci', 'Hsp')
$driverNames = @('WdBoot', 'WdFilter', 'WdNisDrv', 'MsSecFlt', 'MsSecWfp', 'SgrmAgent')
$requiredRegistryNames = @('Disable Mitigation.reg', 'Disable SmartScreen.reg', 'DisableAntivirusProtection.reg',
    'DisableDefenderandSecurityCenterNotifications.reg', 'DisableDefenderPolicies.reg',
    'RemovalofWindowsDefenderAntivirus.reg', 'RemoveDefenderTasks.reg', 'RemoverofDefenderContextMenu.reg',
    'RemoveServices.reg', 'RemoveShellAssociation.reg', 'RemoveSignatureUpdates.reg',
    'RemoveStartupEntries.reg', 'RemoveWindowsWebThreat.reg', 'WindowsSettingsPageVisibility.reg')
$script:activeStage = $Stage
$script:pendingMessages = New-Object 'System.Collections.Generic.List[string]'
$script:operationId = $null

function Write-RemovalLog {
    param([string]$Message, [switch]$Quiet)
    Add-Content -LiteralPath $logPath -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:activeStage, $Message) -Encoding UTF8
    if (-not $Quiet) { Write-Host $Message }
}

function Add-RemovalPending {
    param([string]$Message)
    if (-not $script:pendingMessages.Contains($Message)) { $script:pendingMessages.Add($Message) }
    Write-RemovalLog ('未完成：' + $Message)
}

function Write-RemovalJson {
    param([string]$Path, [object]$Data)
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, ($Data | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Read-RemovalJson {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

function Get-RemovalBootIdentity {
    # Logon triggers may fire while AME is still deploying. Only a later boot may run cleanup.
    $system = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if (-not $system.LastBootUpTime) { throw '无法确认本次系统启动时间，禁止提前运行补清。' }
    return ([datetime]$system.LastBootUpTime).ToUniversalTime().Ticks.ToString()
}

function Read-RemovalManifest {
    $manifest = Read-RemovalJson -Path $manifestPath
    if (-not $manifest) {
        if ($Stage -eq 'Prepare') { return }
        throw '持久化组件目标清单缺失，禁止继续卸载。'
    }
    foreach ($name in @('Services', 'DriverFiles', 'TaskIds')) {
        if ($name -notin $manifest.PSObject.Properties.Name -or $manifest.$name -isnot [array]) {
            throw ('组件目标清单结构无效：' + $name)
        }
    }
    foreach ($name in $serviceNames) {
        if ($name -notin $manifest.Services) { throw ('组件目标清单缺少服务：' + $name) }
    }
    foreach ($name in $manifest.Services) {
        if ($name -notin $serviceNames -and $name -notmatch '^webthreatdefusersvc_[0-9a-f]+$') { throw ('组件目标清单包含未知服务：' + $name) }
    }
    foreach ($path in $manifest.DriverFiles) {
        if (-not (Test-AllowedDriverPath -Path $path)) { throw ('组件目标清单驱动路径无效：' + $path) }
    }
    foreach ($id in $manifest.TaskIds) {
        if ($id -notmatch '^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$') { throw ('组件目标清单任务标识无效：' + $id) }
    }
    return $manifest
}

function Save-RemovalPhase {
    param([string]$Name, [ValidateSet('Running', 'Success', 'Pending', 'Failed')][string]$Status, [string]$ErrorMessage)
    Write-RemovalJson -Path (Join-Path $phaseRoot ($Name + '.json')) -Data ([ordered]@{
        OperationId = $script:operationId
        Stage = $Name
        Status = $Status
        Updated = (Get-Date).ToString('o')
        Issues = @($script:pendingMessages.ToArray())
        Error = $ErrorMessage
    })
}

function Invoke-RemovalCommand {
    param([string]$Executable, [string[]]$Arguments, [int[]]$SuccessCodes = @(0), [switch]$AllowFailure)
    # Resolve before lowering error preference so a launch failure cannot use a stale LASTEXITCODE.
    try { $command = Get-Command -Name $Executable -CommandType Application -ErrorAction Stop }
    catch { $_.Exception.Data['RemovalCommandLaunch'] = $true; throw }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $LASTEXITCODE = $null
    try {
        $commandOutput = & $command.Source @Arguments 2>&1
        $commandExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    foreach ($line in $commandOutput) { Write-RemovalLog -Message ([string]$line) -Quiet }
    if ($null -eq $commandExitCode) {
        $launchException = New-Object InvalidOperationException ('无法启动命令：' + $Executable)
        $launchException.Data['RemovalCommandLaunch'] = $true
        throw $launchException
    }
    if ($commandExitCode -notin $SuccessCodes) {
        $message = '{0} 退出码：{1}' -f $Executable, $commandExitCode
        if (-not $AllowFailure) { throw $message }
        Write-RemovalLog $message
    }
    return [int]$commandExitCode
}

function Get-ServiceSnapshot {
    param([string[]]$Names = @())
    $controllers = @([System.ServiceProcess.ServiceController]::GetServices()) + @([System.ServiceProcess.ServiceController]::GetDevices())
    try {
        foreach ($controller in $controllers) {
            if ($Names.Count -gt 0 -and $controller.ServiceName -notin $Names) { continue }
            # A status-query failure is unknown, not evidence that a service is absent.
            [pscustomobject]@{ Name = $controller.ServiceName; Status = [string]$controller.Status }
        }
    } finally {
        foreach ($controller in $controllers) { $controller.Dispose() }
    }
}

function Get-ServiceTargets {
    $names = @($serviceNames)
    $manifest = Read-RemovalManifest
    if ($manifest) { $names += @($manifest.Services) }
    foreach ($key in (Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services')) {
        try { if ($key.PSChildName -match '^webthreatdefusersvc_[0-9a-f]+$') { $names += $key.PSChildName } }
        finally { $key.Dispose() }
    }
    $names | Where-Object { $_ -in $serviceNames -or $_ -match '^webthreatdefusersvc_[0-9a-f]+$' } | Sort-Object -Unique
}

function Stop-RemovalServices {
    $targets = @(Get-ServiceTargets)
    $snapshot = @(Get-ServiceSnapshot -Names $targets)
    foreach ($name in $targets) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $name
        if (Test-Path -LiteralPath $key) {
            try { Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -Type DWord }
            catch { Add-RemovalPending ('禁用服务启动 {0}：{1}' -f $name, $_.Exception.Message) }
        }
        $service = $snapshot | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($service -and $service.Status -ne 'Stopped') {
            try { Stop-Service -Name $name -Force -ErrorAction Stop }
            catch { Add-RemovalPending ('停止服务 {0}：{1}' -f $name, $_.Exception.Message) }
        }
    }
    foreach ($process in (Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in @('smartscreen', 'SecHealthUI', 'SecurityHealthHost') })) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
        catch { Add-RemovalPending ('停止进程 {0}：{1}' -f $process.ProcessName, $_.Exception.Message) }
    }
}

function Remove-ServiceRegistrations {
    foreach ($name in (Get-ServiceTargets)) {
        $exitCode = Invoke-RemovalCommand -Executable 'sc.exe' -Arguments @('delete', $name) -SuccessCodes @(0, 1060, 1072) -AllowFailure
        if ($exitCode -notin @(0, 1060, 1072)) {
            # Registry import still attempts the upstream removal; the final snapshot decides completion.
            Write-RemovalLog ('服务删除待核对：{0}，退出码 {1}' -f $name, $exitCode)
        }
    }
}

function Get-BaseFileTargets {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if (-not $programFiles -or -not $env:WINDIR -or -not $env:ProgramData) { throw '无法确定卸载目录。' }
    Join-Path $env:ProgramData 'Microsoft\Windows Defender'
    Join-Path $programFiles 'Windows Defender'
    if ($programFilesX86) { Join-Path $programFilesX86 'Windows Defender' }
    Join-Path $programFiles 'Windows Defender Advanced Threat Protection'
    foreach ($name in @('smartscreen.exe', 'smartscreen.dll', 'smartscreenps.dll', 'smartscreen.old')) {
        Join-Path $env:WINDIR ('System32\' + $name)
    }
}

function Test-AllowedDriverPath {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $driversDirectory = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\drivers')).TrimEnd('\')
    $allowedNames = @($driverNames | ForEach-Object { $_ + '.sys' })
    return ([IO.Path]::GetDirectoryName($fullPath) -eq $driversDirectory -and [IO.Path]::GetFileName($fullPath) -in $allowedNames)
}

function Get-DriverFileTargets {
    foreach ($name in $driverNames) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $name
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $serviceKey = Get-Item -LiteralPath $key
        try { $imagePath = [string]$serviceKey.GetValue('ImagePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        finally { $serviceKey.Dispose() }
        if (-not $imagePath) { continue }
        $imagePath = [Environment]::ExpandEnvironmentVariables($imagePath).Trim('"')
        if ($imagePath -match '^\\SystemRoot\\') { $imagePath = Join-Path $env:WINDIR $imagePath.Substring(12) }
        elseif ($imagePath.StartsWith('\??\')) { $imagePath = $imagePath.Substring(4) }
        elseif ($imagePath -match '^System32\\') { $imagePath = Join-Path $env:WINDIR $imagePath }
        if ((Test-AllowedDriverPath -Path $imagePath) -and (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
            [IO.Path]::GetFullPath($imagePath)
        } else { Write-RemovalLog ('未扩展驱动文件目标：{0} → {1}' -f $name, $imagePath) }
    }
}

function Get-RemovalTargets {
    $targets = @(Get-BaseFileTargets)
    $manifest = Read-RemovalManifest
    if ($manifest) {
        foreach ($path in $manifest.DriverFiles) {
            if (-not (Test-AllowedDriverPath -Path $path)) { throw ('驱动文件清单包含不允许的路径：' + $path) }
            $targets += $path
        }
    }
    $targets | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique
}

function Get-TaskCacheIds {
    $ids = @()
    if (Test-Path -LiteralPath $taskTreePath) {
        foreach ($key in (Get-ChildItem -LiteralPath $taskTreePath -Recurse)) {
            try { $id = [string]$key.GetValue('Id') }
            finally { $key.Dispose() }
            if ($id) { $ids += $id }
        }
    }
    $tasksRoot = Join-Path $taskCacheRoot 'Tasks'
    if (Test-Path -LiteralPath $tasksRoot) {
        foreach ($key in (Get-ChildItem -LiteralPath $tasksRoot)) {
            try { $path = [string]$key.GetValue('Path'); $id = $key.PSChildName }
            finally { $key.Dispose() }
            if ($path.StartsWith($defenderTaskPath + '\', [StringComparison]::OrdinalIgnoreCase)) { $ids += $id }
        }
    }
    $ids | Where-Object { $_ -match '^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$' } | Sort-Object -Unique
}

function Save-RemovalManifest {
    $oldManifest = Read-RemovalManifest
    $driverFiles = @(Get-DriverFileTargets)
    $taskIds = @(Get-TaskCacheIds)
    if ($oldManifest) { $driverFiles += @($oldManifest.DriverFiles); $taskIds += @($oldManifest.TaskIds) }
    foreach ($path in $driverFiles) {
        if (-not (Test-AllowedDriverPath -Path $path)) { throw ('不允许的旧驱动目标：' + $path) }
    }
    Write-RemovalJson -Path $manifestPath -Data ([ordered]@{
        Services = @(Get-ServiceTargets)
        DriverFiles = @($driverFiles | Sort-Object -Unique)
        TaskIds = @($taskIds | Where-Object { $_ -match '^\{[0-9a-f-]{36}\}$' } | Sort-Object -Unique)
    })
}

function Assert-DeletionTarget {
    param([string]$Path, [switch]$TaskDirectory)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedPaths = @(Get-RemovalTargets)
    if ($TaskDirectory) { $allowedPaths += [IO.Path]::GetFullPath($taskFilesPath).TrimEnd('\') }
    if ($fullPath -notin $allowedPaths) { throw ('不允许删除的路径：' + $fullPath) }
    # Do not let recursive takeown/icacls follow a junction into another directory.
    $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
    if (Test-Path -LiteralPath $fullPath -PathType Container) { $pendingDirectories.Push($fullPath) }
    $rootItem = Get-Item -LiteralPath $fullPath -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('目标是重解析点：' + $fullPath) }
    while ($pendingDirectories.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $pendingDirectories.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('目标内包含重解析点：' + $item.FullName) }
            if ($item.PSIsContainer) { $pendingDirectories.Push($item.FullName) }
        }
    }
}

function Remove-AllowedFiles {
    param([string]$Path, [switch]$TaskDirectory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Assert-DeletionTarget -Path $Path -TaskDirectory:$TaskDirectory
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        catch {
            Write-RemovalLog ('正在处理文件权限：' + $Path)
            if (Test-Path -LiteralPath $Path -PathType Container) {
                $null = Invoke-RemovalCommand -Executable 'takeown.exe' -Arguments @('/f', $Path, '/a', '/r', '/d', 'Y') -AllowFailure
                $null = Invoke-RemovalCommand -Executable 'icacls.exe' -Arguments @($Path, '/grant', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '/t', '/c', '/q', '/l') -AllowFailure
            } else {
                $null = Invoke-RemovalCommand -Executable 'takeown.exe' -Arguments @('/f', $Path, '/a') -AllowFailure
                $null = Invoke-RemovalCommand -Executable 'icacls.exe' -Arguments @($Path, '/grant', '*S-1-5-18:F', '*S-1-5-32-544:F', '/q', '/l') -AllowFailure
            }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        Write-RemovalLog ('已删除：' + $Path)
    } catch {
        if ($_.Exception.Data.Contains('RemovalCommandLaunch')) { throw }
        Add-RemovalPending ('删除 {0}：{1}' -f $Path, $_.Exception.Message)
    }
}

function Remove-TaskFolderContents {
    param([object]$Folder)
    foreach ($task in @($Folder.GetTasks(1))) {
        try { $task.Stop(0) } catch { Write-RemovalLog ('计划任务停止信息：' + $_.Exception.Message) -Quiet }
        $Folder.DeleteTask($task.Name, 0)
    }
    foreach ($child in @($Folder.GetFolders(0))) {
        Remove-TaskFolderContents -Folder $child
        $Folder.DeleteFolder($child.Name, 0)
    }
}

function Remove-DefenderTasks {
    Save-RemovalManifest
    $scheduler = New-Object -ComObject 'Schedule.Service'
    try {
        $scheduler.Connect()
        try {
            $folder = $scheduler.GetFolder($defenderTaskPath)
            Remove-TaskFolderContents -Folder $folder
            $scheduler.GetFolder('\Microsoft\Windows').DeleteFolder('Windows Defender', 0)
        } catch {
            if ($_.Exception.GetBaseException().HResult -ne -2147024894) {
                Write-RemovalLog ('计划任务 API 清理未完成，将处理已确认的缓存：' + $_.Exception.Message)
            }
        }
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler) }
    $manifest = Read-RemovalManifest
    foreach ($id in $manifest.TaskIds) {
        if ($id -notmatch '^\{[0-9a-f-]{36}\}$') { throw ('任务标识无效：' + $id) }
        foreach ($index in @('Tasks', 'Boot', 'Logon', 'Plain', 'Maintenance')) {
            $key = Join-Path (Join-Path $taskCacheRoot $index) $id
            if (Test-Path -LiteralPath $key) {
                try { Remove-Item -LiteralPath $key -Recurse -Force }
                catch { Add-RemovalPending ('删除任务缓存 {0}：{1}' -f $key, $_.Exception.Message) }
            }
        }
    }
    if (Test-Path -LiteralPath $taskTreePath) {
        try { Remove-Item -LiteralPath $taskTreePath -Recurse -Force }
        catch { Add-RemovalPending ('删除 Defender 任务树：' + $_.Exception.Message) }
    }
    Remove-AllowedFiles -Path $taskFilesPath -TaskDirectory
}

function Register-RemainingCleanup {
    $scriptPath = Join-Path $payloadRoot 'Invoke-DefenderRemoval.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw '持久化补清脚本缺失。' }
    $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage Startup' -f $scriptPath) -WorkingDirectory $payloadRoot
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $bootTrigger.Delay = 'PT30S'
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $logonTrigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger @($bootTrigger, $logonTrigger) -Principal $principal -Settings $settings -Force | Out-Null
    Write-RemovalLog '已准备重启后与登录时的残留补清；重启交由 AME 部署完成流程。'
}

function Remove-CleanupTask {
    $task = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $taskName -and $_.TaskPath -eq '\' })
    if ($task.Count -gt 0) { Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
}

function Get-RemovalIssues {
    foreach ($name in @('Prepare', 'RemoveApp', 'Registry', 'UserRegistry', 'Tasks', 'Files')) {
        $phase = Read-RemovalJson -Path (Join-Path $phaseRoot ($name + '.json'))
        if (-not $phase -or $phase.OperationId -ne $script:operationId -or $phase.Status -in @('Running', 'Failed')) {
            '阶段没有完成：' + $name
        } elseif ($phase.Status -eq 'Pending' -and $name -ne 'Registry') {
            foreach ($issue in $phase.Issues) { '{0}：{1}' -f $name, $issue }
        }
    }
    foreach ($target in (Get-RemovalTargets)) {
        if (Test-Path -LiteralPath $target -ErrorAction Stop) { '文件或目录仍存在：' + $target }
    }
    $targets = @(Get-ServiceTargets)
    foreach ($name in $targets) {
        if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $name)) { '服务注册仍存在：' + $name }
    }
    foreach ($service in (Get-ServiceSnapshot -Names $targets)) {
        if ($service.Name -in $targets) { '服务或驱动仍在 SCM 中：' + $service.Name + ' (' + $service.Status + ')' }
    }
    foreach ($process in (Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in @('MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthHost', 'SecHealthUI', 'smartscreen') })) {
        '组件进程仍在运行：' + $process.ProcessName
    }
    foreach ($package in (Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -like '*SecHealthUI*' })) {
        '已安装应用仍存在：' + $package.PackageFullName
    }
    foreach ($package in (Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -like '*SecHealthUI*' })) {
        '预配应用仍存在：' + $package.PackageName
    }
    Get-RegistryRemovalIssues
    $scheduler = New-Object -ComObject 'Schedule.Service'
    try {
        $scheduler.Connect()
        try {
            $folder = $scheduler.GetFolder($defenderTaskPath)
            if ($folder.GetTasks(1).Count -gt 0 -or $folder.GetFolders(0).Count -gt 0) { 'Defender 计划任务仍存在。' }
        } catch {
            if ($_.Exception.GetBaseException().HResult -ne -2147024894) { throw }
        }
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler) }
    if (Test-Path -LiteralPath $taskTreePath) { 'Defender 任务树仍存在。' }
    if (Test-Path -LiteralPath $taskFilesPath) { 'Defender 任务文件目录仍存在。' }
    foreach ($id in (Get-TaskCacheIds)) { 'Defender 任务缓存仍存在：' + $id }
    $manifest = Read-RemovalManifest
    foreach ($id in $manifest.TaskIds) {
        foreach ($index in @('Tasks', 'Boot', 'Logon', 'Plain', 'Maintenance')) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $taskCacheRoot $index) $id)) { '已确认的任务缓存仍存在：' + $index + '\' + $id }
        }
    }
}

function Complete-Removal {
    param([switch]$AfterRestart)
    $issues = @(Get-RemovalIssues | Sort-Object -Unique)
    if ($issues.Count -eq 0) {
        Remove-CleanupTask
        $status = 'Success'
        $message = 'Defender：目标组件、应用、注册信息、计划任务和文件已全部完成移除。'
    } else {
        Register-RemainingCleanup
        $status = 'PendingReboot'
        if ($AfterRestart) { $status = 'Failed' }
        $message = 'Defender：仍有 {0} 项未完成；已保留补清任务与日志。' -f $issues.Count
        if (-not $AfterRestart) { $message += ' AME 部署完成重启后将继续处理。' }
    }
    Write-RemovalJson -Path $resultPath -Data ([ordered]@{
        OperationId = $script:operationId
        Status = $status
        Updated = (Get-Date).ToString('o')
        Issues = $issues
        Log = $logPath
    })
    $script:pendingMessages.Clear()
    foreach ($issue in $issues) { $script:pendingMessages.Add($issue) }
    $phaseStatus = 'Success'
    if ($status -eq 'PendingReboot') { $phaseStatus = 'Pending' }
    elseif ($status -eq 'Failed') { $phaseStatus = 'Failed' }
    Save-RemovalPhase -Name $script:activeStage -Status $phaseStatus
    if ($AfterRestart) { Save-RemovalPhase -Name Startup -Status $phaseStatus }
    Write-RemovalLog $message
    foreach ($issue in $issues) { Write-RemovalLog $issue -Quiet }
    if ($status -eq 'Failed') { return 1 }
    return 0
}

function Invoke-RemovalPhase {
    param([string]$Name)
    $script:activeStage = $Name
    $script:pendingMessages.Clear()
    Save-RemovalPhase -Name $Name -Status Running
    switch ($Name) {
        'Stop' {
            $exitCode = Invoke-RemovalCommand -Executable 'reg.exe' -Arguments @('add', 'HKLM\SOFTWARE\Microsoft\Windows Defender\Features', '/v', 'TamperProtection', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
            if ($exitCode -ne 0) { Write-RemovalLog ('篡改防护写入未完成，保留实际退出码：' + $exitCode) }
            if ($Stage -ne 'Startup' -and -not $AfterRestart) {
                # Preserve the known-working v0.1.0 stop algorithm and its tolerance of missing history.
                $stopPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & (Join-Path $PSScriptRoot 'StopDefender.ps1') }
                finally { $ErrorActionPreference = $stopPreference; Set-Location -LiteralPath $PSScriptRoot }
            }
            Stop-RemovalServices
        }
        'Wait' {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -eq 'MsMpEng' }) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
            if (Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -eq 'MsMpEng' }) { Add-RemovalPending 'MsMpEng 等待 30 秒后仍运行，留待重启补清。' }
            else { Write-RemovalLog 'MsMpEng 已退出。' }
        }
        'RemoveApp' { Invoke-SecHealthAppRemoval }
        'Registry' { Remove-ServiceRegistrations; Import-RemovalRegistry -Scope Machine }
        'UserRegistry' { Import-RemovalUserRegistry }
        'Tasks' { Remove-DefenderTasks }
        'Files' { foreach ($target in (Get-RemovalTargets)) { Remove-AllowedFiles -Path $target } }
        default { throw ('不支持的内部阶段：' + $Name) }
    }
    $status = 'Success'
    if ($script:pendingMessages.Count -gt 0) { $status = 'Pending' }
    Save-RemovalPhase -Name $Name -Status $status
}

function Invoke-RoutedCleanupPhase {
    param([string]$Name, [int]$TimeoutMilliseconds, [switch]$FinalizeAfterRestart)
    $script:activeStage = $Name
    Write-RemovalLog ('补清阶段：' + $Name)
    $cleanupScript = Join-Path $payloadRoot 'Invoke-DefenderRemoval.ps1'
    if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) { throw '补清主脚本缺失。' }
    # Each child owns the same lock, writes its own stage record and exits before the next starts.
    $script:stateLock.Dispose()
    $script:stateLock = $null
    try {
        if ($Name -in @('Stop', 'Tasks')) {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Stage {1}' -f $cleanupScript, $Name
            if ($Name -eq 'Stop') { $startInfo.Arguments += ' -AfterRestart' }
            $startInfo.WorkingDirectory = $payloadRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $child = New-Object Diagnostics.Process
            try {
                $child.StartInfo = $startInfo
                if (-not $child.Start()) { throw ('无法启动 SYSTEM 补清阶段：' + $Name) }
                if (-not $child.WaitForExit($TimeoutMilliseconds)) {
                    $child.Kill()
                    if (-not $child.WaitForExit(10000)) { throw ('SYSTEM 补清进程未退出：' + $Name) }
                    throw ('SYSTEM 补清阶段超时：' + $Name)
                }
                $exitCode = $child.ExitCode
            } finally { $child.Dispose() }
        } else {
            $exitCode = Invoke-TrustedInstallerCleanupStage -ScriptPath $cleanupScript -Stage $Name -TimeoutMilliseconds $TimeoutMilliseconds -AfterRestart:$FinalizeAfterRestart
        }
    } finally {
        $script:stateLock = [IO.File]::Open((Join-Path $stateRoot 'Removal.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    return [int]$exitCode
}

$stateLock = $null
$resultExitCode = 0
try {
    New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -eq 'Core') { throw '请使用 64 位 Windows PowerShell 执行此任务。' }
    $stateLock = [IO.File]::Open((Join-Path $stateRoot 'Removal.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    New-Item -Path $phaseRoot -ItemType Directory -Force | Out-Null
    . (Join-Path $PSScriptRoot 'RegistryRemoval.ps1')
    . (Join-Path $PSScriptRoot 'RemoveSecHealthApp.ps1')
    . (Join-Path $PSScriptRoot 'TrustedInstallerLauncher.ps1')
    if ($AfterRestart -and $Stage -notin @('Stop', 'Finalize')) { throw 'AfterRestart 仅用于重启后的停止或汇总阶段。' }
    Write-RemovalLog ('开始阶段：' + $Stage)
    # LICENSE 是本目录的署名与许可证说明，不属于运行时资源，缺失不应中止部署。
    foreach ($name in @('Invoke-DefenderRemoval.ps1', 'StopDefender.ps1', 'RemoveSecHealthApp.ps1', 'RegistryRemoval.ps1', 'TrustedInstallerLauncher.ps1', 'Remove_Defender', 'Remove_SecurityComp')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) { throw ('移除资源缺失：' + $name) }
    }
    foreach ($name in $requiredRegistryNames) {
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'Remove_Defender') $name) -PathType Leaf)) { throw ('注册资源缺失：' + $name) }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Remove_SecurityComp\Remove_SecurityComp.reg') -PathType Leaf)) { throw '安全中心注册资源缺失。' }
    if ($Stage -eq 'Prepare') {
        foreach ($name in @('reg.exe', 'sc.exe', 'takeown.exe', 'icacls.exe', 'dism.exe')) {
            Get-Command -Name $name -CommandType Application -ErrorAction Stop | Out-Null
        }
        foreach ($name in @('Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Get-ScheduledTask', 'Register-ScheduledTask', 'Get-CimInstance')) {
            Get-Command -Name $name -ErrorAction Stop | Out-Null
        }
        $null = Invoke-RemovalCommand -Executable 'icacls.exe' -Arguments @($stateRoot, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '/q')
        $script:operationId = [guid]::NewGuid().ToString()
        $preparedBoot = Get-RemovalBootIdentity
        Write-RemovalJson -Path $operationPath -Data ([ordered]@{ OperationId = $script:operationId; Ready = $false; PreparedBoot = $preparedBoot })
        Save-RemovalPhase -Name Prepare -Status Running
        New-Item -Path $payloadRoot -ItemType Directory -Force | Out-Null
        if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($payloadRoot).TrimEnd('\')) {
            foreach ($item in (Get-ChildItem -LiteralPath $PSScriptRoot)) { Copy-Item -LiteralPath $item.FullName -Destination $payloadRoot -Recurse -Force }
        }
        Save-RemovalManifest
        $oldTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq 'XOS-DefenderDisable' -and $_.TaskPath -eq '\' })
        if ($oldTasks.Count -gt 0) { Unregister-ScheduledTask -TaskName 'XOS-DefenderDisable' -TaskPath '\' -Confirm:$false -ErrorAction Stop }
        $oldScript = Join-Path $env:WINDIR 'XOS-DD.ps1'
        if (Test-Path -LiteralPath $oldScript) { Remove-Item -LiteralPath $oldScript -Force }
        Register-RemainingCleanup
        Save-RemovalPhase -Name Prepare -Status Success
        Write-RemovalJson -Path $operationPath -Data ([ordered]@{ OperationId = $script:operationId; Ready = $true; PreparedBoot = $preparedBoot })
    } else {
        $operation = Read-RemovalJson -Path $operationPath
        if (-not $operation -or -not $operation.Ready) { throw '准备阶段未成功完成，禁止继续卸载。' }
        $script:operationId = $operation.OperationId
        $null = Read-RemovalManifest
        if ($Stage -eq 'Startup') {
            if (-not $operation.PreparedBoot) { throw '准备记录缺少系统启动信息，禁止运行补清。' }
            if ($operation.PreparedBoot -eq (Get-RemovalBootIdentity)) {
                Write-RemovalLog '本次部署尚未经过重启，补清任务保留并等待 AME 部署完成后的启动。'
            } else {
                $cleanupTimeouts = @{ Stop = 180000; Wait = 45000; RemoveApp = 600000; Registry = 300000; UserRegistry = 180000; Tasks = 180000; Files = 900000 }
                foreach ($name in @('Stop', 'Wait', 'RemoveApp', 'Registry', 'UserRegistry', 'Tasks', 'Files')) {
                    $phaseExitCode = Invoke-RoutedCleanupPhase -Name $name -TimeoutMilliseconds $cleanupTimeouts[$name]
                    if ($phaseExitCode -ne 0) { throw ('重启补清阶段失败：{0}，退出码 {1}' -f $name, $phaseExitCode) }
                }
                $script:activeStage = 'Startup'
                $resultExitCode = Invoke-RoutedCleanupPhase -Name Finalize -TimeoutMilliseconds 120000 -FinalizeAfterRestart
            }
        } elseif ($Stage -eq 'Finalize') {
            Save-RemovalPhase -Name Finalize -Status Running
            $resultExitCode = Complete-Removal -AfterRestart:$AfterRestart
        }
        else { Invoke-RemovalPhase -Name $Stage }
    }
} catch {
    $message = $_.Exception.Message
    if ($stateLock) {
        try {
            Save-RemovalPhase -Name $script:activeStage -Status Failed -ErrorMessage $message
            Write-RemovalJson -Path $resultPath -Data ([ordered]@{
                OperationId = $script:operationId; Status = 'Failed'; Updated = (Get-Date).ToString('o'); Issues = @($message); Log = $logPath
            })
            Write-RemovalLog ('阶段失败：' + $message)
        } catch { Write-Error ('失败结果记录异常：' + $_.Exception.Message) -ErrorAction Continue }
    }
    Write-Error -Message $message -ErrorAction Continue
    $resultExitCode = 1
} finally {
    if ($stateLock) { $stateLock.Dispose() }
}
exit $resultExitCode
