# Registry import and result tracking for the complete upstream removal data.
# Dot-source this file from Invoke-DefenderRemoval.ps1; do not execute it directly.
$script:registryResourceRoot = $PSScriptRoot

function Get-RemovalRegistryResources {
    param([string[]]$Names = @())
    $files = @(Get-ChildItem -LiteralPath (Join-Path $script:registryResourceRoot 'Remove_Defender') -Filter '*.reg' -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $script:registryResourceRoot 'Remove_SecurityComp') -Filter '*.reg' -File)
    $files = @($files | Sort-Object Name, FullName)
    if ($Names.Count -gt 0) {
        foreach ($name in $Names) {
            if ($name -notin $files.Name) { throw "Missing registry resource: $name" }
        }
        $files = @($files | Where-Object { $_.Name -in $Names })
    }
    return $files
}

function ConvertFrom-RemovalRegistryData {
    param([string]$Text)
    if ($Text -eq '-') { return [pscustomobject]@{ Exists = $false; Kind = ''; Data = $null } }
    if ($Text -match '^"((?:[^"\\]|\\.)*)"$') {
        return [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = [regex]::Replace($Matches[1], '\\(["\\])', '$1') }
    }
    if ($Text -match '^dword:([0-9a-fA-F]{8})$') {
        return [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Data = [Convert]::ToUInt32($Matches[1], 16) }
    }
    if ($Text -match '^hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') {
        $type = [string]$Matches[1]
        $hex = $Matches[2]
        $bytes = [byte[]]@()
        if ($hex.Length -gt 0) {
            if ($hex -notmatch '^[0-9a-fA-F]{2}(,[0-9a-fA-F]{2})*$') { throw "Malformed registry hex data: $Text" }
            $bytes = [byte[]]@($hex.Split(',') | ForEach-Object { [Convert]::ToByte($_, 16) })
        }
        switch ($type) {
            '' { return [pscustomobject]@{ Exists = $true; Kind = 'Binary'; Data = $bytes } }
            'b' {
                if ($bytes.Length -ne 8) { throw 'Registry QWord data must contain eight bytes.' }
                return [pscustomobject]@{ Exists = $true; Kind = 'QWord'; Data = [BitConverter]::ToInt64($bytes, 0) }
            }
            '2' {
                return [pscustomobject]@{ Exists = $true; Kind = 'ExpandString'; Data = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
            }
            '7' {
                $strings = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0).Split([char]0)
                return [pscustomobject]@{ Exists = $true; Kind = 'MultiString'; Data = [string[]]$strings }
            }
            default { throw "Unsupported registry data type: hex($type)" }
        }
    }
    throw "Unsupported registry data: $Text"
}

function Get-RemovalRegistryDocument {
    param([System.IO.FileInfo]$File, [ValidateSet('Machine', 'User')][string]$Scope, [string]$UserSid = '', [ValidateSet('All', 'Profile', 'Classes')][string]$UserHive = 'All')
    if ($Scope -eq 'User' -and $UserSid -notmatch '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$') { throw 'A real user SID is required for HKCU imports.' }
    $sourceLines = [IO.File]::ReadAllLines($File.FullName)
    if ($sourceLines.Count -eq 0 -or $sourceLines[0] -ne 'Windows Registry Editor Version 5.00') { throw "Invalid registry header: $($File.Name)" }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $lines.Add('Windows Registry Editor Version 5.00')
    $lines.Add('')
    $keep = $false
    $currentPath = ''
    for ($index = 1; $index -lt $sourceLines.Count; $index++) {
        $line = $sourceLines[$index].Trim()
        $lineNumber = $index + 1
        if ($line -match '^\[(-?)(HKEY_[A-Z_]+)\\([^\[\]]+)\]$') {
            $deleting = $Matches[1] -eq '-'
            $root = $Matches[2]
            $relative = $Matches[3]
            $keep = ($Scope -eq 'User' -and $root -eq 'HKEY_CURRENT_USER') -or ($Scope -eq 'Machine' -and $root -ne 'HKEY_CURRENT_USER')
            $isUserClasses = $root -eq 'HKEY_CURRENT_USER' -and ($relative -eq 'Software\Classes' -or $relative.StartsWith('Software\Classes\', [StringComparison]::OrdinalIgnoreCase))
            if ($Scope -eq 'User' -and $UserHive -eq 'Profile' -and $isUserClasses) { $keep = $false }
            if ($Scope -eq 'User' -and $UserHive -eq 'Classes' -and -not $isUserClasses) { $keep = $false }
            if (-not $keep) { continue }
            switch ($root) {
                'HKEY_CLASSES_ROOT' { $currentPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\' + $relative }
                'HKEY_CURRENT_USER' {
                    if ($isUserClasses) {
                        $currentPath = 'HKEY_USERS\' + $UserSid + '_Classes'
                        if ($relative.Length -gt 'Software\Classes'.Length) { $currentPath += $relative.Substring('Software\Classes'.Length) }
                    } else { $currentPath = 'HKEY_USERS\' + $UserSid + '\' + $relative }
                }
                'HKEY_LOCAL_MACHINE' { $currentPath = $root + '\' + $relative }
                'HKEY_USERS' { $currentPath = $root + '\' + $relative }
                default { throw "Unsupported registry hive in $($File.Name): $root" }
            }
            $prefix = ''
            $operationType = 'EnsureKey'
            if ($deleting) { $prefix = '-'; $operationType = 'DeleteKey' }
            $lines.Add('[' + $prefix + $currentPath + ']')
            $operations.Add([pscustomobject]@{ Type = $operationType; Path = $currentPath; Name = ''; Value = $null; Source = $File.Name; Line = $lineNumber })
            continue
        }
        if (-not $keep) { continue }
        if ($line -eq '' -or $line.StartsWith(';')) { $lines.Add($line); continue }
        while ($line.EndsWith('\')) {
            $line = $line.Substring(0, $line.Length - 1)
            $index++
            if ($index -ge $sourceLines.Count) { throw "Unterminated registry value in $($File.Name):$lineNumber" }
            $line += $sourceLines[$index].Trim()
        }
        if ($line -notmatch '^("((?:[^"\\]|\\.)*)"|@)=(.*)$') { throw "Malformed registry value in $($File.Name):$lineNumber" }
        $valueName = ''
        if ($Matches[1] -ne '@') { $valueName = [regex]::Replace($Matches[2], '\\(["\\])', '$1') }
        $value = ConvertFrom-RemovalRegistryData -Text $Matches[3]
        $lines.Add($line)
        $operations.Add([pscustomobject]@{ Type = 'Value'; Path = $currentPath; Name = $valueName; Value = $value; Source = $File.Name; Line = $lineNumber })
    }
    return [pscustomobject]@{ Lines = $lines.ToArray(); Operations = $operations.ToArray() }
}

function Get-RemovalRegistryDesiredState {
    param([object[]]$Operations)
    $desired = @{}
    $resetRoots = @{}
    foreach ($operation in $Operations) {
        $path = $operation.Path
        if ($operation.Type -eq 'DeleteKey') {
            foreach ($knownPath in @($desired.Keys)) {
                if ($knownPath -eq $path -or $knownPath.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { $desired.Remove($knownPath) }
            }
            $resetRoots[$path] = [pscustomobject]@{ Path = $path; Source = $operation.Source; Line = $operation.Line }
            $desired[$path] = [pscustomobject]@{ Exists = $false; Values = @{}; Source = $operation.Source; Line = $operation.Line }
            continue
        }
        # A recreated descendant also recreates any previously deleted ancestor.
        foreach ($knownPath in @($desired.Keys)) {
            if (-not $desired[$knownPath].Exists -and $path.StartsWith($knownPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $desired[$knownPath].Exists = $true
                $desired[$knownPath].Source = $operation.Source
                $desired[$knownPath].Line = $operation.Line
            }
        }
        if (-not $desired.ContainsKey($path)) {
            $desired[$path] = [pscustomobject]@{ Exists = $true; Values = @{}; Source = $operation.Source; Line = $operation.Line }
        } else {
            $desired[$path].Exists = $true
            $desired[$path].Source = $operation.Source
            $desired[$path].Line = $operation.Line
        }
        if ($operation.Type -eq 'Value') {
            $desired[$path].Values[$operation.Name] = [pscustomobject]@{ Value = $operation.Value; Source = $operation.Source; Line = $operation.Line }
        }
    }
    $recreatedRoots = @($resetRoots.Keys | Where-Object { $desired.ContainsKey($_) -and $desired[$_].Exists })
    $rootRecords = @($recreatedRoots | Where-Object {
        $candidate = $_
        -not ($recreatedRoots | Where-Object { $_ -ne $candidate -and $candidate.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
    } | ForEach-Object { $resetRoots[$_] })
    return [pscustomobject]@{ Keys = $desired; ResetRoots = $rootRecords }
}

function Read-RemovalRegistryKey {
    param([string]$Path)
    if ($Path -notmatch '^(HKEY_LOCAL_MACHINE|HKEY_USERS)\\(.+)$') { throw "Unsupported registry path: $Path" }
    $relative = $Matches[2]
    $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
    if ($Matches[1] -eq 'HKEY_USERS') { $hive = [Microsoft.Win32.RegistryHive]::Users }
    $base = $null
    $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey($relative, $false)
        if ($null -eq $key) { return [pscustomobject]@{ Exists = $false; Values = @{} } }
        $values = @{}
        foreach ($name in $key.GetValueNames()) {
            $values[$name] = [pscustomobject]@{ Kind = $key.GetValueKind($name).ToString(); Data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        }
        return [pscustomobject]@{ Exists = $true; Values = $values }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Test-RemovalRegistryValueData {
    param([object]$Actual, [object]$Expected)
    if ($Actual.Kind -ne $Expected.Kind) { return $false }
    switch ($Expected.Kind) {
        'DWord' { return (([int64]$Actual.Data -band 4294967295L) -eq [int64]$Expected.Data) }
        'QWord' { return ([int64]$Actual.Data -eq [int64]$Expected.Data) }
        'Binary' { return ([Convert]::ToBase64String([byte[]]$Actual.Data) -ceq [Convert]::ToBase64String([byte[]]$Expected.Data)) }
        'MultiString' { return ([string]::Join([char]0, [string[]]$Actual.Data) -ceq [string]::Join([char]0, [string[]]$Expected.Data)) }
        default { return ([string]$Actual.Data -ceq [string]$Expected.Data) }
    }
}

function Format-RemovalRegistryValue {
    param([object]$Value)
    if ($null -eq $Value) { return '(不存在)' }
    if ($Value.Kind -eq 'Binary') { return 'Binary:' + [BitConverter]::ToString([byte[]]$Value.Data) }
    if ($Value.Kind -eq 'MultiString') { return 'MultiString:' + ([string[]]$Value.Data -join ';') }
    return $Value.Kind + ':' + [string]$Value.Data
}

function Get-RemovalRegistryResetIssues {
    param([object]$Desired, [object]$Root)
    $allowedKeys = @{}
    foreach ($path in $Desired.Keys.Keys) {
        if (-not $Desired.Keys[$path].Exists -or ($path -ne $Root.Path -and -not $path.StartsWith($Root.Path + '\', [StringComparison]::OrdinalIgnoreCase))) { continue }
        $ancestor = $path
        while ($ancestor.Length -ge $Root.Path.Length) {
            $allowedKeys[$ancestor] = $true
            if ($ancestor -eq $Root.Path) { break }
            $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('\'))
        }
    }
    $base = $null
    try {
        if ($Root.Path -notmatch '^(HKEY_LOCAL_MACHINE|HKEY_USERS)\\(.+)$') { throw ('Unsupported reset root: ' + $Root.Path) }
        $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
        if ($Matches[1] -eq 'HKEY_USERS') { $hive = [Microsoft.Win32.RegistryHive]::Users }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
        $paths = New-Object 'System.Collections.Generic.Queue[string]'
        $paths.Enqueue($Root.Path)
        while ($paths.Count -gt 0) {
            $path = $paths.Dequeue()
            $key = $null
            try {
                $relative = $path.Substring($path.IndexOf('\') + 1)
                $key = $base.OpenSubKey($relative, $false)
                if ($null -eq $key) { continue }
                if (-not $allowedKeys.ContainsKey($path)) {
                    [pscustomobject]@{ Source = $Root.Source; Message = ('删除后重建的注册表键仍有额外子键：{0}（删除来源 {1}:{2}）；保留为待清项，不扩大删除范围。' -f $path, $Root.Source, $Root.Line) }
                    continue
                }
                foreach ($name in $key.GetValueNames()) {
                    $allowed = $Desired.Keys.ContainsKey($path) -and $Desired.Keys[$path].Exists -and $Desired.Keys[$path].Values.ContainsKey($name) -and $Desired.Keys[$path].Values[$name].Value.Exists
                    if (-not $allowed) {
                        $displayName = $name
                        if ($name -eq '') { $displayName = '(Default)' }
                        [pscustomobject]@{ Source = $Root.Source; Message = ('删除后重建的注册表键仍有额外值：{0}\{1}（删除来源 {2}:{3}）；保留为待清项。' -f $path, $displayName, $Root.Source, $Root.Line) }
                    }
                }
                foreach ($child in $key.GetSubKeyNames()) { $paths.Enqueue($path + '\' + $child) }
            } finally { if ($null -ne $key) { $key.Dispose() } }
        }
    } catch {
        $_.Exception.Data['RegistryReadFatal'] = $true
        throw
    } finally { if ($null -ne $base) { $base.Dispose() } }
}

function Get-RemovalRegistryStateIssues {
    param([object]$Desired)
    foreach ($path in ($Desired.Keys.Keys | Sort-Object)) {
        $expectedKey = $Desired.Keys[$path]
        try {
            $actualKey = Read-RemovalRegistryKey -Path $path
            if ($actualKey.Exists -ne $expectedKey.Exists) {
                $requirement = '应不存在'
                if ($expectedKey.Exists) { $requirement = '应存在' }
                [pscustomobject]@{ Source = $expectedKey.Source; Message = ('{0}：{1}，最终注册表状态未达标。' -f $path, $requirement) }
                continue
            }
            if (-not $expectedKey.Exists) { continue }
            foreach ($name in $expectedKey.Values.Keys) {
                $entry = $expectedKey.Values[$name]
                $hasValue = $actualKey.Values.ContainsKey($name)
                $valid = $hasValue -eq $entry.Value.Exists
                if ($valid -and $hasValue) { $valid = Test-RemovalRegistryValueData -Actual $actualKey.Values[$name] -Expected $entry.Value }
                if (-not $valid) {
                    $displayName = $name
                    if ($name -eq '') { $displayName = '(Default)' }
                    $actual = $null
                    if ($hasValue) { $actual = $actualKey.Values[$name] }
                    $expected = $null
                    if ($entry.Value.Exists) { $expected = $entry.Value }
                    [pscustomobject]@{ Source = $entry.Source; Message = ('{0}\{1}：应为 {2}，实际 {3}（来源 {4}:{5}）。' -f $path, $displayName, (Format-RemovalRegistryValue -Value $expected), (Format-RemovalRegistryValue -Value $actual), $entry.Source, $entry.Line) }
                }
            }
        } catch {
            $_.Exception.Data['RegistryReadFatal'] = $true
            throw
        }
    }
    foreach ($root in $Desired.ResetRoots) { Get-RemovalRegistryResetIssues -Desired $Desired -Root $root }
}

function New-RemovalRegistryStatus {
    param([string]$Scope)
    return [pscustomobject]@{ Version = 1; Scope = $Scope; UpdatedUtc = ''; CompleteImport = $false; Files = @(); Profiles = @(); NativeFailures = @(); DiscoveryIssues = @(); SettingsVisibility = $null; ReadIssues = @() }
}

function Read-RemovalRegistryStatus {
    param([string]$Scope)
    $status = New-RemovalRegistryStatus -Scope $Scope
    $path = Join-Path $stateRoot ('Registry' + $Scope + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $status }
    try {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($saved.Version -ne 1 -or $saved.Scope -ne $Scope) { throw 'Unsupported registry result format.' }
        foreach ($name in @('UpdatedUtc', 'CompleteImport', 'Files', 'Profiles', 'DiscoveryIssues', 'SettingsVisibility')) {
            $property = $saved.PSObject.Properties[$name]
            if ($null -eq $property) { throw "Missing registry result property: $name" }
            $status.$name = $property.Value
        }
        $history = $saved.PSObject.Properties['NativeFailures']
        if ($null -ne $history) { $status.NativeFailures = @($history.Value) }
    } catch { $status.ReadIssues = @('无法读取注册表阶段结果：' + $_.Exception.Message) }
    return $status
}

function Save-RemovalRegistryStatus {
    param([object]$Status)
    $Status.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $Status.ReadIssues = @()
    $path = Join-Path $stateRoot ('Registry' + $Status.Scope + '.json')
    $temporary = $path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Status | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Invoke-RemovalRegistryNative {
    param([string[]]$Arguments)
    try { return [int](Invoke-RemovalCommand -Executable 'reg.exe' -Arguments $Arguments -AllowFailure) }
    catch {
        # A process-launch failure is fatal; a native nonzero status is tracked below.
        $_.Exception.Data['RegistryCommandLaunch'] = $true
        throw
    }
}

function Invoke-RemovalRegistryBatch {
    param([object[]]$Files, [ValidateSet('Machine', 'User')][string]$Scope, [string]$UserSid = '', [ValidateSet('All', 'Profile', 'Classes')][string]$UserHive = 'All')
    $outputRoot = Join-Path $stateRoot ('Registry\' + $Scope)
    if ($Scope -eq 'User') { $outputRoot = Join-Path (Join-Path $outputRoot $UserSid) $UserHive }
    New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null
    $records = New-Object 'System.Collections.Generic.List[object]'
    $operations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $Files) {
        $record = [pscustomobject]@{ Name = $file.Name; Hive = $UserHive; NativeExitCode = $null; NativeFailures = @(); Issues = @(); HadSections = $false }
        $records.Add($record)
        $document = Get-RemovalRegistryDocument -File $file -Scope $Scope -UserSid $UserSid -UserHive $UserHive
        foreach ($operation in $document.Operations) { $operations.Add($operation) }
        if ($document.Operations.Count -eq 0) { continue }
        $record.HadSections = $true
        $importPath = Join-Path $outputRoot $file.Name
        [IO.File]::WriteAllLines($importPath, $document.Lines, [Text.Encoding]::Unicode)
        try {
            $record.NativeExitCode = Invoke-RemovalRegistryNative -Arguments @('import', $importPath, '/reg:64')
        } catch {
            $message = '无法启动注册表导入 ' + $file.Name + '：' + $_.Exception.Message
            $record.Issues += $message
            $record.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = $Scope; Sid = $UserSid; Source = $file.Name; ExitCode = $null; Message = $message }
            $_.Exception.Data['RegistryBatchRecords'] = $records.ToArray()
            $null = Add-RemovalPending -Message $message
            throw
        }
        if ($record.NativeExitCode -ne 0) {
            $message = 'reg.exe import {0} 返回退出码 {1}，具体原生输出见 DefenderRemoval.log。' -f $file.Name, $record.NativeExitCode
            $record.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = $Scope; Sid = $UserSid; Source = $file.Name; ExitCode = $record.NativeExitCode; Message = $message }
        }
        Write-RemovalLog ('注册表资源已处理：{0} ({1}{2})，退出码 {3}。' -f $file.Name, $Scope, $UserSid, $record.NativeExitCode)
    }
    # Native failures remain diagnostic history. Pending items describe only the
    # final state after every source file, including intentionally deleted/recreated keys.
    try {
        $desired = Get-RemovalRegistryDesiredState -Operations $operations.ToArray()
        foreach ($issue in @(Get-RemovalRegistryStateIssues -Desired $desired)) {
            $record = $records | Where-Object { $_.Name -eq $issue.Source } | Select-Object -First 1
            if ($null -ne $record) { $record.Issues += $issue.Message }
        }
    } catch {
        $_.Exception.Data['RegistryBatchRecords'] = $records.ToArray()
        throw
    }
    return $records.ToArray()
}

function Set-DefenderSettingsVisibility {
    $relative = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $result = [pscustomobject]@{ Original = ''; Expected = ''; Issues = @() }
    $base = $null
    $key = $null
    # Reading the existing configuration must succeed before deciding how to merge it.
    $snapshot = Read-RemovalRegistryKey -Path ('HKEY_LOCAL_MACHINE\' + $relative)
    try {
        if ($snapshot.Values.ContainsKey('SettingsPageVisibility')) { $result.Original = [string]$snapshot.Values['SettingsPageVisibility'].Data }
        if ([string]::IsNullOrWhiteSpace($result.Original)) { $result.Expected = 'hide:windowsdefender' }
        elseif ($result.Original -match '^(hide|showonly):(.*)$') {
            $mode = $Matches[1].ToLowerInvariant()
            $pages = @($Matches[2].Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if ($mode -eq 'hide') {
                if ('windowsdefender' -notin $pages) { $pages += 'windowsdefender' }
            } else { $pages = @($pages | Where-Object { $_ -ine 'windowsdefender' }) }
            $result.Expected = $mode + ':' + ($pages -join ';')
        } else { throw ('无法合并不受支持的 SettingsPageVisibility 内容：' + $result.Original) }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.CreateSubKey($relative)
        $key.SetValue('SettingsPageVisibility', $result.Expected, [Microsoft.Win32.RegistryValueKind]::String)
        if ([string]$key.GetValue('SettingsPageVisibility') -cne $result.Expected) { throw 'SettingsPageVisibility 写入后读取不一致。' }
    } catch { $result.Issues += ('Defender 设置页面隐藏未完成：' + $_.Exception.Message) }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
    return $result
}

function Import-RemovalRegistry {
    param([ValidateSet('Machine')][string]$Scope = 'Machine', [string[]]$Names = @())
    $files = @(Get-RemovalRegistryResources -Names $Names)
    $status = Read-RemovalRegistryStatus -Scope Machine
    # Only selected file records are replaced; a later full import replaces all of them.
    $selectedNames = @($files | ForEach-Object { $_.Name })
    $status.Files = @($status.Files | Where-Object { $_.Name -notin $selectedNames })
    $status.DiscoveryIssues = @()
    if ($Names.Count -eq 0) { $status.CompleteImport = $false }
    try {
        $newRecords = @(Invoke-RemovalRegistryBatch -Files $files -Scope Machine)
        $status.Files += $newRecords
        foreach ($record in $newRecords) { $status.NativeFailures += @($record.NativeFailures) }
        if ($Names.Count -eq 0 -or 'WindowsSettingsPageVisibility.reg' -in $Names) {
            $status.SettingsVisibility = Set-DefenderSettingsVisibility
        }
        if ($Names.Count -eq 0) { $status.CompleteImport = $true }
    } catch {
        if ($_.Exception.Data.Contains('RegistryBatchRecords')) {
            $failedRecords = @($_.Exception.Data['RegistryBatchRecords'])
            $status.Files += $failedRecords
            foreach ($record in $failedRecords) { $status.NativeFailures += @($record.NativeFailures) }
        }
        $status.DiscoveryIssues = @('机器注册表阶段异常：' + $_.Exception.Message)
        $null = Add-RemovalPending -Message $status.DiscoveryIssues[0]
        throw
    } finally {
        Save-RemovalRegistryStatus -Status $status
        foreach ($record in $status.Files) { foreach ($issue in $record.Issues) { $null = Add-RemovalPending -Message $issue } }
        if ($null -ne $status.SettingsVisibility) { foreach ($issue in $status.SettingsVisibility.Issues) { $null = Add-RemovalPending -Message $issue } }
    }
}

function Get-RemovalUserProfiles {
    $profiles = @{}
    $base = $null
    $profileList = $null
    $profileKey = $null
    $users = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $profileList = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList', $false)
        if ($null -eq $profileList) { throw 'ProfileList 不存在。' }
        foreach ($sid in $profileList.GetSubKeyNames()) {
            if ($sid -notmatch '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$') { continue }
            try {
                $profileKey = $profileList.OpenSubKey($sid, $false)
                if ($null -eq $profileKey) { throw ('无法读取 ProfileList 用户：' + $sid) }
                $profilePath = [Environment]::ExpandEnvironmentVariables([string]$profileKey.GetValue('ProfileImagePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
                $profiles[$sid] = [pscustomobject]@{ Sid = $sid; ProfilePath = $profilePath; Loaded = $false; ClassesLoaded = $false }
            } finally {
                if ($null -ne $profileKey) { $profileKey.Dispose(); $profileKey = $null }
            }
        }
        $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
        foreach ($mountName in $users.GetSubKeyNames()) {
            $sid = $mountName -replace '_Classes$', ''
            if ($sid -notmatch '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$') { continue }
            if (-not $profiles.ContainsKey($sid)) { $profiles[$sid] = [pscustomobject]@{ Sid = $sid; ProfilePath = ''; Loaded = $false; ClassesLoaded = $false } }
            if ($mountName -like '*_Classes') { $profiles[$sid].ClassesLoaded = $true }
            else { $profiles[$sid].Loaded = $true }
        }
    } finally {
        if ($null -ne $profileKey) { $profileKey.Dispose() }
        if ($null -ne $profileList) { $profileList.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
        if ($null -ne $users) { $users.Dispose() }
    }
    return @($profiles.Values | Sort-Object Sid)
}

function Stop-RemovalUnavailableHive {
    param([string]$Message)
    $exception = New-Object InvalidOperationException $Message
    $exception.Data['RegistryHiveUnavailable'] = $true
    throw $exception
}

function Import-RemovalUserRegistry {
    $status = Read-RemovalRegistryStatus -Scope Users
    $status.CompleteImport = $false
    $status.Profiles = @()
    $status.DiscoveryIssues = @()
    $files = @(Get-RemovalRegistryResources)
    $records = New-Object 'System.Collections.Generic.List[object]'
    try {
        $profiles = @(Get-RemovalUserProfiles)
        if ($profiles.Count -eq 0) { $status.DiscoveryIssues += '未发现可处理的真实用户 ProfileList 或已加载用户配置单元。' }
        foreach ($profile in $profiles) {
            $record = [pscustomobject]@{ Sid = $profile.Sid; ProfilePath = $profile.ProfilePath; Hives = @(); Files = @(); NativeFailures = @(); Issues = @() }
            $records.Add($record)
            try {
                foreach ($userHive in @('Profile', 'Classes')) {
                    $mountName = $profile.Sid
                    $relativeFile = 'NTUSER.DAT'
                    if ($userHive -eq 'Classes') { $mountName += '_Classes'; $relativeFile = 'AppData\Local\Microsoft\Windows\UsrClass.dat' }
                    $hiveRecord = [pscustomobject]@{ Hive = $userHive; MountName = $mountName; HivePath = ''; LoadedByThisProcess = $false; CompleteImport = $false; Files = @(); NativeFailures = @(); Issues = @() }
                    $record.Hives += $hiveRecord
                    try {
                        $loaded = (Read-RemovalRegistryKey -Path ('HKEY_USERS\' + $mountName)).Exists
                        if (-not $loaded) {
                            if ([string]::IsNullOrWhiteSpace($profile.ProfilePath) -or -not [IO.Path]::IsPathRooted($profile.ProfilePath)) { Stop-RemovalUnavailableHive 'ProfileList 没有有效的绝对 ProfileImagePath。' }
                            $profilePath = [IO.Path]::GetFullPath($profile.ProfilePath).TrimEnd('\')
                            $hiveRecord.HivePath = [IO.Path]::GetFullPath((Join-Path $profilePath $relativeFile))
                            if (-not $hiveRecord.HivePath.StartsWith($profilePath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw ('用户配置单元路径不在其 ProfileList 目录内：' + $hiveRecord.HivePath) }
                            if (-not (Test-Path -LiteralPath $hiveRecord.HivePath -PathType Leaf)) { Stop-RemovalUnavailableHive ('用户配置单元文件不存在：' + $hiveRecord.HivePath) }
                            $exitCode = Invoke-RemovalRegistryNative -Arguments @('load', ('HKU\' + $mountName), $hiveRecord.HivePath)
                            if ($exitCode -ne 0) {
                                $message = 'reg.exe load ' + $mountName + ' 返回退出码 ' + $exitCode + '，具体原生输出见 DefenderRemoval.log。'
                                $hiveRecord.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = 'User'; Sid = $profile.Sid; Hive = $userHive; Source = 'reg.exe load'; ExitCode = $exitCode; Message = $message }
                                # A sign-in can load either hive after discovery. Never unload a hive we did not load.
                                if (-not (Read-RemovalRegistryKey -Path ('HKEY_USERS\' + $mountName)).Exists) { Stop-RemovalUnavailableHive $message }
                            } else { $hiveRecord.LoadedByThisProcess = $true }
                        }
                        $hiveRecord.Files = @(Invoke-RemovalRegistryBatch -Files $files -Scope User -UserSid $profile.Sid -UserHive $userHive)
                        foreach ($fileRecord in $hiveRecord.Files) {
                            $hiveRecord.Issues += @($fileRecord.Issues)
                            $hiveRecord.NativeFailures += @($fileRecord.NativeFailures)
                        }
                        $hiveRecord.CompleteImport = $true
                    } catch {
                        if ($_.Exception.Data.Contains('RegistryBatchRecords')) {
                            $hiveRecord.Files = @($_.Exception.Data['RegistryBatchRecords'])
                            foreach ($fileRecord in $hiveRecord.Files) { $hiveRecord.NativeFailures += @($fileRecord.NativeFailures) }
                        }
                        $hiveRecord.Issues += ('用户 ' + $profile.Sid + ' 的 ' + $userHive + ' 注册表未完成：' + $_.Exception.Message)
                        if ($_.Exception.Data.Contains('RegistryCommandLaunch') -and -not $_.Exception.Data.Contains('RegistryBatchRecords')) {
                            $hiveRecord.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = 'User'; Sid = $profile.Sid; Hive = $userHive; Source = 'reg.exe load'; ExitCode = $null; Message = $_.Exception.Message }
                        }
                        if (-not $_.Exception.Data.Contains('RegistryHiveUnavailable')) { throw }
                    } finally {
                        if ($hiveRecord.LoadedByThisProcess) {
                            # Dispose every registry handle before unloading this independently mounted hive.
                            [GC]::Collect()
                            [GC]::WaitForPendingFinalizers()
                            try {
                                $unloadCode = Invoke-RemovalRegistryNative -Arguments @('unload', ('HKU\' + $mountName))
                                if ($unloadCode -ne 0) {
                                    $message = '用户 ' + $profile.Sid + ' 的 ' + $userHive + ' 配置单元卸载失败，reg.exe 返回退出码 ' + $unloadCode + '。'
                                    $hiveRecord.Issues += $message
                                    $hiveRecord.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = 'User'; Sid = $profile.Sid; Hive = $userHive; Source = 'reg.exe unload'; ExitCode = $unloadCode; Message = $message }
                                }
                            } catch {
                                $hiveRecord.Issues += ('用户 ' + $profile.Sid + ' 的 ' + $userHive + ' 配置单元卸载异常：' + $_.Exception.Message)
                                $hiveRecord.NativeFailures += [pscustomobject]@{ AtUtc = [DateTime]::UtcNow.ToString('o'); Scope = 'User'; Sid = $profile.Sid; Hive = $userHive; Source = 'reg.exe unload'; ExitCode = $null; Message = $_.Exception.Message }
                                throw
                            }
                        }
                    }
                }
            } finally {
                foreach ($hiveRecord in $record.Hives) {
                    $record.Files += @($hiveRecord.Files)
                    $record.Issues += @($hiveRecord.Issues)
                    $record.NativeFailures += @($hiveRecord.NativeFailures)
                }
                $status.NativeFailures += @($record.NativeFailures)
                foreach ($issue in $record.Issues) { $null = Add-RemovalPending -Message $issue }
            }
        }
        $status.CompleteImport = $true
    } catch {
        $status.DiscoveryIssues += ('用户注册表阶段异常：' + $_.Exception.Message)
        foreach ($issue in $status.DiscoveryIssues) { $null = Add-RemovalPending -Message $issue }
        throw
    } finally {
        $status.Profiles = $records.ToArray()
        Save-RemovalRegistryStatus -Status $status
    }
}

function Get-RegistryRemovalIssues {
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $machine = Read-RemovalRegistryStatus -Scope Machine
    $users = Read-RemovalRegistryStatus -Scope Users
    foreach ($status in @($machine, $users)) {
        if (@($status.ReadIssues).Count -gt 0) { throw (@($status.ReadIssues) -join '; ') }
        foreach ($issue in @($status.DiscoveryIssues)) { $issues.Add([string]$issue) }
        if (-not $status.CompleteImport) { $issues.Add('注册表完整导入尚未完成：' + $status.Scope) }
    }
    # Machine mismatches are history; the live final ordered manifest is authoritative.
    foreach ($profile in $users.Profiles) { foreach ($issue in $profile.Issues) { $issues.Add([string]$issue) } }
    try {
        $operations = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in @(Get-RemovalRegistryResources)) {
            $document = Get-RemovalRegistryDocument -File $file -Scope Machine
            foreach ($operation in $document.Operations) { $operations.Add($operation) }
        }
        $desired = Get-RemovalRegistryDesiredState -Operations $operations.ToArray()
        foreach ($issue in @(Get-RemovalRegistryStateIssues -Desired $desired)) { $issues.Add([string]$issue.Message) }
        # Critical policy expectations are included in the same final ordered state:
        # DisableAntiSpyware=1, DisableRealtimeMonitoring=1, Security Health Registered=0.
        if ($null -eq $machine.SettingsVisibility) { $issues.Add('Defender 设置页面隐藏阶段尚未完成。') }
        else {
            if ([string]::IsNullOrWhiteSpace([string]$machine.SettingsVisibility.Expected)) { $issues.Add('Defender 设置页面合并目标没有生成，无法验证完成。') }
            $visibility = Read-RemovalRegistryKey -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            if (-not $visibility.Values.ContainsKey('SettingsPageVisibility') -or $visibility.Values['SettingsPageVisibility'].Kind -ne 'String' -or [string]$visibility.Values['SettingsPageVisibility'].Data -cne [string]$machine.SettingsVisibility.Expected) {
                $issues.Add('SettingsPageVisibility 与已保存的合并结果不一致。')
            }
        }
    } catch { throw }
    return @($issues.ToArray() | Select-Object -Unique)
}
