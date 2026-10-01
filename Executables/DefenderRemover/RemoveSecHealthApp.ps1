# Adapted from ionuttbara/windows-defender-remover/script/RemoveSecHealthApp.ps1.
# CC BY-NC 4.0; see LICENSE. Invoked only through Invoke-DefenderRemoval.ps1.

function Invoke-SecHealthAppRemoval {
    $ErrorActionPreference = 'Stop'

    # Missing dependencies and failed queries are fatal: they cannot prove absence.
    foreach ($name in @('Write-RemovalLog', 'Add-RemovalPending', 'Invoke-RemovalCommand')) {
        if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Required wrapper function is missing: $name"
        }
    }
    foreach ($name in @('Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Remove-AppxPackage', 'Remove-AppxProvisionedPackage')) {
        Get-Command -Name $name -ErrorAction Stop | Out-Null
    }
    $dismPath = (Get-Command -Name 'dism.exe' -CommandType Application -ErrorAction Stop).Source
    $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $packages = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -like '*SecHealthUI*' })
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -like '*SecHealthUI*' })

    $userSids = New-Object 'System.Collections.Generic.List[string]'
    $userSids.Add('S-1-5-18')
    foreach ($package in $packages) {
        foreach ($user in @($package.PackageUserInformation)) {
            $sid = [string]$user.UserSecurityId
            if ($sid -match '^S-\d+-\d+(?:-\d+)+$') { $userSids.Add($sid) }
        }
    }
    foreach ($root in @($store, $profileList)) {
        if (Test-Path -LiteralPath $root -ErrorAction Stop) {
            foreach ($item in (Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                if ($item.PSChildName -match '^S-1-(?:5-21|12-1)-\d+(?:-\d+)*$') {
                    $userSids.Add($item.PSChildName)
                }
            }
        }
    }
    $userSids = @($userSids | Select-Object -Unique)

    function Resolve-RemovalPackageFamily {
        param([object]$Package, [switch]$Provisioned)
        $family = ''
        if ($Provisioned) {
            $family = $packages | Where-Object { $_.Name -eq $Package.DisplayName } |
                Select-Object -First 1 -ExpandProperty PackageFamilyName
            $fullName = [string]$Package.PackageName
        } else {
            $family = [string]$Package.PackageFamilyName
            $fullName = [string]$Package.PackageFullName
        }
        if ([string]::IsNullOrWhiteSpace($family)) {
            # Full names contain name, version, architecture, resource and publisher fields.
            $parts = $fullName -split '_'
            if ($parts.Count -ge 5) { $family = '{0}_{1}' -f $parts[0], $parts[-1] }
        }
        if ([string]::IsNullOrWhiteSpace($family) -or $family -match '[\\/]') {
            throw "Cannot resolve a valid package family for $fullName."
        }
        return [string]$family
    }

    function Set-RemovalAppPolicy {
        param([string]$PackageFamilyName, [string]$PackageName)
        if ([string]::IsNullOrWhiteSpace($PackageName) -or $PackageName -match '[\\/]') {
            throw 'Cannot resolve a valid package name for Windows Security removal.'
        }
        $policyKeys = @("$store\Deprovisioned\$PackageFamilyName")
        foreach ($sid in $userSids) { $policyKeys += "$store\EndOfLife\$sid\$PackageName" }
        foreach ($key in $policyKeys) {
            try {
                New-Item -Path $key -Force -ErrorAction Stop | Out-Null
            } catch {
                Add-RemovalPending ('安全中心包策略待处理：{0}；{1}；{2}' -f $PackageName, $key, $_.Exception.Message)
            }
        }
        try {
            $dismExitCode = Invoke-RemovalCommand -Executable $dismPath -Arguments @(
                '/Online', '/Set-NonRemovableAppPolicy', ('/PackageFamily:' + $PackageFamilyName),
                '/NonRemovable:0', '/NoRestart'
            ) -SuccessCodes @(0, 3010) -AllowFailure
            if ($dismExitCode -eq 3010) {
                Add-RemovalPending ('安全中心包策略需要重启：{0}；DISM 退出码 3010。' -f $PackageName)
            } elseif ($dismExitCode -ne 0) {
                Add-RemovalPending ('安全中心包策略待处理：{0}；DISM 退出码 {1}。' -f $PackageName, $dismExitCode)
            } else {
                Write-RemovalLog ('已解除安全中心包不可移除策略：{0}' -f $PackageName)
            }
        } catch {
            if ($_.Exception.Data.Contains('RemovalCommandLaunch')) { throw }
            Add-RemovalPending ('安全中心包策略待处理：{0}；{1}' -f $PackageName, $_.Exception.Message)
        }
    }

    foreach ($package in $provisioned) {
        $packageName = [string]$package.PackageName
        try {
            $family = Resolve-RemovalPackageFamily -Package $package -Provisioned
            Set-RemovalAppPolicy -PackageFamilyName $family -PackageName $packageName
            $removalResult = Remove-AppxProvisionedPackage -PackageName $packageName -Online -AllUsers -ErrorAction Stop
            if ($removalResult.RestartNeeded) {
                Add-RemovalPending ('预配安全中心包移除需要重启：{0}' -f $packageName)
            }
            Write-RemovalLog ('已请求移除预配安全中心包：{0}' -f $packageName)
        } catch {
            if ($_.Exception.Data.Contains('RemovalCommandLaunch')) { throw }
            Add-RemovalPending ('预配安全中心包移除待处理：{0}；{1}' -f $packageName, $_.Exception.Message)
        }
    }

    foreach ($package in $packages) {
        $packageName = [string]$package.PackageFullName
        # Provisioned removal can already remove the registration. Query failures stay fatal.
        $currentPackages = @(Get-AppxPackage -AllUsers -ErrorAction Stop |
            Where-Object { $_.PackageFullName -eq $packageName })
        if ($currentPackages.Count -eq 0) {
            Write-RemovalLog ('安全中心包注册已不存在：{0}' -f $packageName)
            continue
        }
        try {
            $family = Resolve-RemovalPackageFamily -Package $package
            Set-RemovalAppPolicy -PackageFamilyName $family -PackageName $packageName
            Remove-AppxPackage -Package $packageName -AllUsers -ErrorAction Stop | Out-Null
            Write-RemovalLog ('已请求移除所有用户的安全中心包：{0}' -f $packageName)
        } catch {
            if ($_.Exception.Data.Contains('RemovalCommandLaunch')) { throw }
            Add-RemovalPending ('已安装安全中心包移除待处理：{0}；{1}' -f $packageName, $_.Exception.Message)
        }
    }

    # The wrapper checks both collections again before declaring overall success.
    Write-RemovalLog ('安全中心包阶段已处理：{0} 个预配包、{1} 个已安装包；最终状态由主流程核验。' -f $provisioned.Count, $packages.Count)
}
